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
    /// Stable owner even before pi has written a session file.
    var agentID: String?
    var agentConfiguration: (() -> Agent?)?
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
    @Published var queuedSteering: [String] = []
    @Published var queuedFollowUps: [String] = []
    @Published var queuedImageCount = 0
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
            errorID = UUID()
            errorSource = errorText == Self.liveUpdatesUnavailableNotice ? .liveUpdates : .other
            retryErrorID = nil
            if errorText != oldValue { dismissedErrorToast = nil }
        }
    }
    @Published var dismissedErrorToast: String?

    enum ErrorSource {
        case other, assistant, liveUpdates
    }

    var errorID = UUID()
    var errorSource: ErrorSource = .other
    var retryErrorID: UUID?
    var recentExtensionNotices: [String: Date] = [:]
    @Published var sessionTree: SessionTreeSnapshot?
    @Published var sessionTreeLoadState: SessionTreeLoadState = .idle
    @Published var isForking = false
    @Published var composerPrefillRequest: ComposerPrefillRequest?
    @Published var extensionUIPrompt: ExtensionUIPrompt?
    @Published var extensionUINotifications: [ExtensionUINotification] = []
    @Published var extensionUIStatuses: [String: String] = [:]
    @Published var claudeBridgeUsageHeaders: String?

    var claudeBridgeUsage: UsageLimitSnapshot? {
        claudeBridgeUsageHeaders.flatMap { ClaudeBridgeUsageService.snapshot(from: $0) }
    }
    /// Live state of tools run by `background` jobs, keyed by the `background` call id.
    @Published var backgroundJobTools: [String: ToolDisplay] = [:]
    @Published var extensionUIWidgets: [String: ExtensionUIWidget] = [:]
    @Published var extensionWindowTitle: String?
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

    @Published var failedPrompt: FailedPromptSubmission?
    @Published var isSendingPrompt = false

    struct QueuedImageSubmission {
        var composerText: String
        var images: [ImageAttachment]
    }

    var rpc: PiRPCClient?
    var rpcStartupTask: Task<Void, Error>?
    var rpcStartupRevision = 0
    var runtimeLoadingSuspended = false
    var quickChatClosed = false
    var isStartingNewChat = false
    let closedQuickChatNotice = "This quick chat is closed. Its transcript is read-only because its unsaved agent context was unloaded. Start a new quick chat to continue."
    var streamingAccumulator: StreamingAssistantAccumulator?
    var streamingAccumulatorNeedsSnapshot = false
    var streamingMessageID: String?
    var streamingTargetMessage: ChatMessage?
    var streamingRevealScheduled = false
    var streamingRevealGeneration = 0
    let streamingRevealInterval: TimeInterval = 1.0 / 30.0
    /// Paragraph mode spaces reveals at least this far apart so each
    /// paragraph's fade (`StreamingFade.duration`) visibly plays, after T3 Code.
    let paragraphRevealInterval: TimeInterval = 0.4
    var lastTextRevealAt = Date.distantPast
    let createdAsNewSession: Bool
    var hasExplicitModelSelection = false
    var hasExplicitThinkingSelection = false
    var automaticTitleGenerationStarted = false
    var automaticTitleRequestID: UUID?
    var automaticTitleTask: Task<Void, Never>?
    var queuedImageSubmissions: [QueuedImageSubmission] = []
    var extensionUIPromptQueue: [ExtensionUIPrompt] = []
    var extensionUITimeoutTasks: [String: Task<Void, Never>] = [:]
    var launchResources: PiLaunchResources
    @Published var chatResources: [PiResourceItem] = []
    var launchResourcesFrozen = false
    let recoveryRequests: SessionRecoveryRequests?
    let eventHandler: (Event) -> Void
    var recoveryTimerTask: Task<Void, Never>?
    var recoveryCheckInFlight = false
    var recoveryRevision = 0
    var runtimeGeneration = 0

    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]
    static let liveUpdatesUnavailableNotice = "Live updates unavailable; work may still be running."
    static let recoveryInterval: UInt64 = 30_000_000_000

    init(
        projectPath: String,
        sessionPath: String?,
        title: String,
        messages: [ChatMessage],
        kind: SessionKind = .persistent,
        extensionPaths: [String] = [],
        recoveryRequests: SessionRecoveryRequests? = nil,
        agentID: String? = nil,
        agentConfiguration: (() -> Agent?)? = nil,
        eventHandler: @escaping (Event) -> Void
    ) {
        self.projectPath = projectPath
        self.kind = agentID == nil ? kind : .persistent
        self.agentID = agentID
        self.agentConfiguration = agentConfiguration
        self.sessionPath = sessionPath
        self.title = title
        self.messages = messages
        self.launchResources = PiLaunchResources(extensions: extensionPaths)
        self.recoveryRequests = recoveryRequests
        self.eventHandler = eventHandler
        self.createdAsNewSession = sessionPath == nil && messages.isEmpty
        if self.createdAsNewSession {
            self.selectedModelID = agentConfiguration?()?.modelID ?? DefaultModelSchedule.effectiveModelID() ?? ""
            self.thinkingLevel = agentConfiguration?()?.thinking ?? GlobalThinkingSelection.level
        }
        Task { [weak self] in await self?.loadConfiguredModels() }
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
    /// Set while the `background` extension reports running jobs through its status.
    var hasBackgroundJobs: Bool { extensionUIStatuses["background"] != nil }
    /// Work that stopping the pi process would kill: an active run or background jobs.
    var hasLiveWork: Bool { showsActivityIndicator || hasBackgroundJobs }
    var hiddenMessageCount: Int { max(0, messages.count - visibleMessageLimit) }
    var visibleMessages: [ChatMessage] { Array(messages.suffix(visibleMessageLimit)) }

    func loadEarlierMessages() {
        visibleMessageLimit = min(messages.count, visibleMessageLimit + 100)
    }

    func scrollToMessage(_ messageID: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return }
        visibleMessageLimit = max(visibleMessageLimit, messages.count - index)
        messageScrollRequest = MessageScrollRequest(messageID: messageID)
    }

    static let builtinNotices: [String: String] = [
        "settings": "Settings available in the GUI: model picker, thinking picker, runtime policy, context meter. Other pi settings remain available in the terminal TUI via `/settings`.",
        "hotkeys": "**GUI Hotkeys**\n\n| Key | Action |\n|---|---|\n| `Return` | Send |\n| `Shift+Return` | New line |\n| `Tab` | Complete `/slash-command` or `@filename` |\n| `Shift+Tab` | Cycle pinned models |\n| `Cmd+1`–`Cmd+5` | Select quick models configured in Settings |\n| `/` | Slash command suggestions |\n| `!cmd` | Bash into context |\n| `!!cmd` | Hidden bash |",
        "resume": "Press ⇧⌘F to find and resume chats. The GUI keeps open chats in the sidebar instead of opening pi's TUI `/resume` picker.",
        "scoped-models": "Scoped model selection is TUI-only. Use `/model <name>` or the toolbar model picker in PiG.",
        "trust": "PiG automatically trusts projects explicitly added or created here. Projects discovered from chat history are not bulk-trusted.",
        "share": "`/share` is TUI-only. Use `/export [file.html]`, then share the exported file.",
        "login": "`/login` is interactive auth UI in terminal pi. Run `pi` in a terminal and use `/login`, or edit provider credentials in `\(PiPaths.agentDir.path)`.",
        "logout": "`/logout` is interactive auth UI in terminal pi. Run `pi` in a terminal and use `/logout`, or edit provider credentials in `\(PiPaths.agentDir.path)`."
    ]


}
