import Foundation
import SwiftUI
import AppKit
@preconcurrency import UserNotifications

enum SessionArchiveLoadState: Equatable {
    case idle
    case loading
    case loaded
}

enum ModelCatalogLoadState: Equatable {
    case loading
    case loaded
    case failed(String)
}

struct SessionRenameRequest: Identifiable {
    var id: String { filePath }
    let filePath: String
    let title: String
}

struct SessionDeletionRequest: Identifiable {
    var id: String { filePath }
    let filePath: String
    let projectPath: String
    let title: String
}

struct InboxDismissalUndo {
    let items: [(id: String, index: Int)]
    let selectedControllerID: String?
    let selectedHermesChatID: String?
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var sessionsByProject: [String: [SessionSummary]] = [:]
    @Published var archivedSessionsByProject: [String: [SessionSummary]] = [:]
    @Published var sessionArchiveLoadState: SessionArchiveLoadState = .idle
    @Published var sessionPendingDeletion: SessionDeletionRequest?
    @Published var sessionPendingRename: SessionRenameRequest?
    /// Themed in-window dialog, drawn by RootView above everything else.
    @Published var dialog: GlowDialogRequest?
    @Published var controllers: [String: SessionController] = [:]
    @Published var selectedControllerID: String?
    @Published var finishedUnseenControllerIDs: Set<String> = []
    @Published var sessionInboxIDs: [String] = SessionInboxStore.ids {
        didSet { SessionInboxStore.save(sessionInboxIDs) }
    }
    @Published var inboxDismissalUndo: InboxDismissalUndo?
    // Agents (see AppModel+Agents.swift).
    @Published var agents: [Agent] = AgentStore.load()
    /// Set only for agent landings and Hermes chats; pi threads use selectedControllerID.
    @Published var selectedAgentID: String?
    @Published var selectedHermesChatID: String?
    @Published var hermesLandingDraftController: HermesChatController?
    @Published var agentSessionRecords = AgentSessionStore.load()
    @Published var agentRecentSessions: [String: [SessionSummary]] = [:]
    @Published var agentEditorRequest: AgentEditorRequest?
    @Published var agentEditorInSettings = false
    /// Hermes controllers keyed by chat UUID.
    @Published var hermesControllers: [String: HermesChatController] = [:]
    @Published var hermesChats: [HermesChatRecord] = HermesChatStore.load()
    /// Hermes replies finished while their chat was not selected.
    @Published var hermesUnreadChatIDs: Set<String> = []
    @Published private(set) var pinnedResourceIDs: [String] = PinnedResourceStore.ids {
        didSet { PinnedResourceStore.save(pinnedResourceIDs) }
    }
    @Published var selectedProjectPath: String?
    @Published var newChatHomeRequestID = 0
    @Published var composingQuickChat = false
    @Published var landingDraftController: SessionController?
    let landingDraft = LandingDraft()
    var landingDraftText: String {
        get { landingDraft.text }
        set { landingDraft.text = newValue }
    }
    var landingDraftImages: [ImageAttachment] {
        get { landingDraft.images }
        set { landingDraft.images = newValue }
    }
    var pendingLandingModelSelection: (controllerID: String, modelID: String)?
    @Published var composerFocusAccent: Bool = ComposerFocusAccentPreference.enabled {
        didSet { ComposerFocusAccentPreference.enabled = composerFocusAccent }
    }
    @Published var showThinkingTraces: Bool = ThinkingTracePreference.enabled {
        didSet { ThinkingTracePreference.enabled = showThinkingTraces }
    }
    var fileTreeExpandedByProject: [String: Set<String>] = [:]
    @Published var showingSessionTree: Bool = false
    @Published var textSizeStep: Int = TextSizePreference.step {
        didSet { TextSizePreference.step = textSizeStep }
    }
    @Published var interfaceFont: InterfaceFont = FontPreference.interface {
        didSet { FontPreference.interface = interfaceFont }
    }
    @Published var codeFont: CodeFont = FontPreference.code {
        didSet { FontPreference.code = codeFont }
    }
    var textStyle: TextStyle {
        TextStyle(sizeStep: textSizeStep, interfaceFont: interfaceFont, codeFont: codeFont)
    }
    @Published var selectedTheme: AppThemeChoice = AppThemeChoice.stored {
        didSet { AppThemeChoice.stored = selectedTheme }
    }
    @Published var sessionRuntimePolicy: SessionRuntimePolicy = SessionRuntimePolicy.stored {
        didSet { SessionRuntimePolicy.stored = sessionRuntimePolicy }
    }
    @Published var notificationsEnabled: Bool = NotificationPreference.enabled {
        didSet { NotificationPreference.enabled = notificationsEnabled }
    }
    @Published var hiddenExtensionStatusKeys: Set<String> = ExtensionStatusVisibilityPreference.hiddenKeys {
        didSet { ExtensionStatusVisibilityPreference.hiddenKeys = hiddenExtensionStatusKeys }
    }
    @Published var newSessionModelMode: NewSessionModelMode = DefaultModelSchedule.mode {
        didSet { DefaultModelSchedule.mode = newSessionModelMode; refreshLandingModelDefaults() }
    }
    @Published var singleSessionModelID: String = DefaultModelSchedule.singleModelID ?? "" {
        didSet { DefaultModelSchedule.singleModelID = singleSessionModelID; refreshLandingModelDefaults() }
    }
    @Published var scheduledWorkModelID: String = DefaultModelSchedule.workModelID ?? "" {
        didSet { DefaultModelSchedule.workModelID = scheduledWorkModelID; refreshLandingModelDefaults() }
    }
    @Published var scheduledOffHoursModelID: String = DefaultModelSchedule.offHoursModelID ?? "" {
        didSet { DefaultModelSchedule.offHoursModelID = scheduledOffHoursModelID; refreshLandingModelDefaults() }
    }
    @Published var scheduledWorkWeekdays: Set<Int> = DefaultModelSchedule.workWeekdays {
        didSet { DefaultModelSchedule.workWeekdays = scheduledWorkWeekdays; refreshLandingModelDefaults() }
    }
    @Published var scheduledStartMinutes: Int = DefaultModelSchedule.startMinutes {
        didSet { DefaultModelSchedule.startMinutes = scheduledStartMinutes; refreshLandingModelDefaults() }
    }
    @Published var scheduledEndMinutes: Int = DefaultModelSchedule.endMinutes {
        didSet { DefaultModelSchedule.endMinutes = scheduledEndMinutes; refreshLandingModelDefaults() }
    }
    @Published var scheduledTimeZoneID: String = DefaultModelSchedule.timeZoneID {
        didSet { DefaultModelSchedule.timeZoneID = scheduledTimeZoneID; refreshLandingModelDefaults() }
    }
    @Published var defaultThinkingLevel: String = GlobalThinkingSelection.level {
        didSet { GlobalThinkingSelection.level = defaultThinkingLevel; refreshLandingModelDefaults() }
    }
    @Published var automaticSessionNamingEnabled: Bool = SessionNamingPreference.enabled {
        didSet { SessionNamingPreference.enabled = automaticSessionNamingEnabled }
    }
    @Published var sessionNamingModelMode: SessionNamingModelMode = SessionNamingPreference.modelMode {
        didSet { SessionNamingPreference.modelMode = sessionNamingModelMode }
    }
    @Published var sessionNamingModelID: String = SessionNamingPreference.modelID ?? "" {
        didSet { SessionNamingPreference.modelID = sessionNamingModelID }
    }
    @Published var sessionNamingThinkingLevel: String = SessionNamingPreference.thinkingLevel {
        didSet { SessionNamingPreference.thinkingLevel = sessionNamingThinkingLevel }
    }
    @Published private(set) var sessionNamingModels: [ModelInfo] = []
    @Published private(set) var modelCatalogLoadState: ModelCatalogLoadState = .loading
    let statusCenter = StatusCenter()
    var statusLine: String {
        get { statusCenter.line }
        set { statusCenter.line = newValue }
    }
    @Published var sessionsGeneratingTitles: Set<String> = []
    let usageLimitStore = UsageLimitStore()
    var usageLimits: [UsageLimitProvider: UsageLimitSnapshot] {
        get { usageLimitStore.limits }
        set { usageLimitStore.limits = newValue }
    }
    @Published var customActionsByProject: [String: ProjectCustomActions] = [:]
    let piMaintenance = PiMaintenanceController()
    let appUpdates = AppUpdateChecker()

    private var terminationObserver: NSObjectProtocol?
    var sessionRefreshGeneration = 0
    var sessionArchiveLoadGeneration = 0
    var activeControllerIDs: Set<String> = []
    struct LandingCommandKey: Hashable {
        let projectPath: String
        let resourceIDs: [String]
    }
    var slashCommandCatalogByProject: [LandingCommandKey: [SlashCommandInfo]] = [:]
    var slashCommandCatalogLoadingPaths: Set<LandingCommandKey> = []
    var slashCommandCatalogGeneration = 0
    var landingModelCatalogByProject: [String: [ModelInfo]] = [:]
    var landingModelCatalogLoadingPaths: Set<String> = []
    var landingModelCatalogGeneration = 0
    var projectTrustTasks: [String: Task<Void, Error>] = [:]
    var usageLimitTask: Task<Void, Never>?
    var usageLimitActivationObserver: NSObjectProtocol?
    var usageLimitDeactivationObserver: NSObjectProtocol?
    var usageLimitFetchDates: [UsageLimitProvider: Date] = [:]
    var sessionUnloadTask: Task<Void, Never>?

    let idleUnloadInterval: TimeInterval = 30 * 60
    let maxLoadedIdleSessions = 3

    var selectedController: SessionController? {
        guard let selectedControllerID else { return nil }
        return controllers[selectedControllerID]
    }

    var activeComposerController: SessionController? {
        selectedController ?? (selectedControllerID == nil ? landingDraftController : nil)
    }

    var extensionPromptController: SessionController? {
        if let selectedController, selectedController.extensionUIPrompt != nil { return selectedController }
        if let landingDraftController, landingDraftController.extensionUIPrompt != nil { return landingDraftController }
        return controllers.values
            .filter { $0.extensionUIPrompt != nil }
            .sorted { $0.lastRuntimeUse > $1.lastRuntimeUse }
            .first
    }

    var extensionNotificationPresentations: [ExtensionUINotificationPresentation] {
        controllers.values
            .flatMap { controller in
                controller.extensionUINotifications.map {
                    ExtensionUINotificationPresentation(controller: controller, notification: $0)
                }
            }
    }

    var extensionStatusKeys: [String] {
        var keys = hiddenExtensionStatusKeys
        for controller in controllers.values {
            keys.formUnion(controller.extensionUIStatuses.keys)
        }
        return keys.sorted()
    }

    func extensionStatusLabel(for key: String) -> String {
        if let text = selectedController?.extensionUIStatuses[key], !text.isEmpty { return text }
        return controllers.values.compactMap { $0.extensionUIStatuses[key] }.first ?? key
    }

    var selectedCustomActions: [CustomAction] {
        guard let projectPath = selectedController?.projectPath else { return [] }
        return customActionsByProject[projectPath]?.actions ?? []
    }

    var selectedLastCustomActionID: String? {
        guard let projectPath = selectedController?.projectPath else { return nil }
        return customActionsByProject[projectPath]?.lastActionID
    }

    var quickChatControllers: [SessionController] {
        controllers.values
            .filter(\.isQuickChat)
            .sorted { lhs, rhs in
                if lhs.id == selectedControllerID { return true }
                if rhs.id == selectedControllerID { return false }
                return lhs.lastRuntimeUse > rhs.lastRuntimeUse
            }
    }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.shutdown()
            }
        }
        piMaintenance.onModelsUpdated = { [weak self] in
            Task { await self?.refreshModelsAfterCatalogUpdate() }
        }
        appUpdates.start()
        Task { [weak self] in
            guard let self else { return }
            await self.loadRegistry()
            let maintenanceProject = self.selectedProject ?? self.projects.first
            self.piMaintenance.start(
                cwd: maintenanceProject?.path ?? PiPaths.home.path,
                projectName: maintenanceProject?.displayName
            )
            await self.loadPersistedInboxSummaries()
            self.refreshSessions()

            async let customActions: Void = self.loadCustomActions()
            async let namingModels: Void = self.loadSessionNamingModels()
            _ = await (customActions, namingModels)

            self.startUsageLimitPolling()
            self.startSessionUnloadPolling()
        }
    }

    deinit {
        usageLimitTask?.cancel()
        sessionUnloadTask?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        if let usageLimitActivationObserver {
            NotificationCenter.default.removeObserver(usageLimitActivationObserver)
        }
        if let usageLimitDeactivationObserver {
            NotificationCenter.default.removeObserver(usageLimitDeactivationObserver)
        }
    }

    func isResourcePinned(_ id: String) -> Bool {
        pinnedResourceIDs.contains(id)
    }

    func toggleResourcePinned(_ id: String) {
        if let index = pinnedResourceIDs.firstIndex(of: id) {
            pinnedResourceIDs.remove(at: index)
        } else {
            pinnedResourceIDs.append(id)
        }
    }

    func movePinnedResource(_ draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              pinnedResourceIDs.contains(draggedID),
              pinnedResourceIDs.contains(targetID) else { return }
        pinnedResourceIDs.removeAll { $0 == draggedID }
        guard let targetIndex = pinnedResourceIDs.firstIndex(of: targetID) else {
            pinnedResourceIDs.append(draggedID)
            return
        }
        pinnedResourceIDs.insert(draggedID, at: targetIndex + (after ? 1 : 0))
    }

    func runCustomAction(_ action: CustomAction) {
        guard let selectedController else {
            statusLine = "Select a chat before running a custom action."
            return
        }
        var bucket = customActionsByProject[selectedController.projectPath] ?? ProjectCustomActions()
        bucket.lastActionID = action.id
        customActionsByProject[selectedController.projectPath] = bucket
        saveCustomActions()
        Task { await selectedController.runCustomAction(action) }
    }

    func upsertCustomAction(_ action: CustomAction) {
        guard let projectPath = selectedController?.projectPath else {
            statusLine = "Select a chat before editing custom actions."
            return
        }
        var bucket = customActionsByProject[projectPath] ?? ProjectCustomActions()
        if let index = bucket.actions.firstIndex(where: { $0.id == action.id }) {
            bucket.actions[index] = action
        } else {
            bucket.actions.append(action)
        }
        customActionsByProject[projectPath] = bucket
        saveCustomActions()
    }

    func deleteCustomAction(_ action: CustomAction) {
        guard let projectPath = selectedController?.projectPath else { return }
        var bucket = customActionsByProject[projectPath] ?? ProjectCustomActions()
        bucket.actions.removeAll { $0.id == action.id }
        if bucket.lastActionID == action.id {
            bucket.lastActionID = bucket.actions.first?.id
        }
        customActionsByProject[projectPath] = bucket
        saveCustomActions()
    }

    func setExtensionStatusHidden(_ key: String, hidden: Bool) {
        if hidden {
            hiddenExtensionStatusKeys.insert(key)
        } else {
            hiddenExtensionStatusKeys.remove(key)
        }
    }

    private func loadCustomActions() async {
        customActionsByProject = await CustomActionStore.load()
    }

    func reloadModelCatalog() {
        Task { await loadSessionNamingModels() }
    }

    func loadSessionNamingModels() async {
        modelCatalogLoadState = .loading
        var modelsByID = Dictionary(uniqueKeysWithValues: (await ModelCatalog.configuredModelsAsync()).map { ($0.id, $0) })
        let client = PiRPCClient(projectPath: PiPaths.home.path, noSession: true)
        var loadError: String?
        do {
            try await client.start()
            let response = try await client.command(["type": "get_available_models"])
            guard let data = response["data"] as? [String: Any],
                  let modelDicts = data["models"] as? [[String: Any]] else {
                throw PiRPCClient.RPCError.commandFailed("Could not read the available model catalog.")
            }
            for model in modelDicts.compactMap(ModelInfo.from) {
                modelsByID[model.id] = model
            }
            client.stop()
        } catch {
            loadError = error.localizedDescription
            client.stop()
        }

        sessionNamingModels = EnabledModelScope.scopedModels(
            Array(modelsByID.values),
            projectPath: nil
        ).sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        if let landingDraftController,
           landingModelCatalogByProject[landingDraftController.projectPath] == nil,
           !landingModelCatalogLoadingPaths.contains(landingDraftController.projectPath) {
            applyLandingModels(sessionNamingModels, to: landingDraftController)
        }
        if let loadError {
            modelCatalogLoadState = .failed(loadError)
        } else if modelsByID.isEmpty {
            modelCatalogLoadState = .failed("No configured models were found.")
        } else {
            modelCatalogLoadState = .loaded
        }
    }

    private func saveCustomActions() {
        let snapshot = customActionsByProject
        CustomActionStore.save(snapshot) { [weak self] error in
            self?.statusLine = "Could not save custom actions: \(error.localizedDescription)"
        }
    }

}
