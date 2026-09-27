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

private struct InboxDismissalUndo {
    let items: [(id: String, index: Int)]
    let selectedControllerID: String?
    let title: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var projects: [ProjectInfo] = []
    @Published var sessionsByProject: [String: [SessionSummary]] = [:]
    @Published private(set) var archivedSessionsByProject: [String: [SessionSummary]] = [:]
    @Published private(set) var sessionArchiveLoadState: SessionArchiveLoadState = .idle
    @Published var sessionPendingDeletion: SessionDeletionRequest?
    @Published var sessionPendingRename: SessionRenameRequest?
    @Published var controllers: [String: SessionController] = [:]
    @Published var selectedControllerID: String?
    @Published var finishedUnseenControllerIDs: Set<String> = []
    @Published private(set) var sessionInboxIDs: [String] = SessionInboxStore.ids {
        didSet { SessionInboxStore.save(sessionInboxIDs) }
    }
    @Published private var inboxDismissalUndo: InboxDismissalUndo?
    @Published private(set) var pinnedResourceIDs: [String] = PinnedResourceStore.ids {
        didSet { PinnedResourceStore.save(pinnedResourceIDs) }
    }
    @Published var selectedProjectPath: String?
    @Published private(set) var newChatHomeRequestID = 0
    @Published private(set) var composingQuickChat = false
    @Published private(set) var landingDraftController: SessionController?
    @Published var landingDraftText = ""
    @Published var landingDraftImages: [ImageAttachment] = []
    private var pendingLandingModelSelection: (controllerID: String, modelID: String)?
    @Published var sidebarVisible: Bool = SidebarPreference.visible {
        didSet { SidebarPreference.visible = sidebarVisible }
    }
    @Published var composerFocusAccent: Bool = ComposerFocusAccentPreference.enabled {
        didSet { ComposerFocusAccentPreference.enabled = composerFocusAccent }
    }
    @Published var showThinkingTraces: Bool = ThinkingTracePreference.enabled {
        didSet { ThinkingTracePreference.enabled = showThinkingTraces }
    }
    @Published var projectHeaderStyle: ProjectHeaderStyle = ProjectHeaderStyle.stored {
        didSet { ProjectHeaderStyle.stored = projectHeaderStyle }
    }
    @Published var sidebarMode: SidebarMode = .sessions
    private var fileTreeExpandedByProject: [String: Set<String>] = [:]
    @Published var showingPiResources: Bool = false
    @Published var showingSessionTree: Bool = false
    @Published var textSizeStep: Int = TextSizePreference.step {
        didSet { TextSizePreference.step = textSizeStep }
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
    @Published var statusLine: String = ""
    @Published var usageLimits: [UsageLimitProvider: UsageLimitSnapshot] = [:]
    @Published var customActionsByProject: [String: ProjectCustomActions] = [:]
    @Published private(set) var sessionLaunchExtensions: [PiResourceItem] = []
    let piMaintenance = PiMaintenanceController()

    private var terminationObserver: NSObjectProtocol?
    private var sessionRefreshGeneration = 0
    private var sessionArchiveLoadGeneration = 0
    private var activeControllerIDs: Set<String> = []
    private struct LandingCommandKey: Hashable {
        let projectPath: String
        let resourceIDs: [String]
    }
    private var slashCommandCatalogByProject: [LandingCommandKey: [SlashCommandInfo]] = [:]
    private var slashCommandCatalogLoadingPaths: Set<LandingCommandKey> = []
    private var slashCommandCatalogGeneration = 0
    private var landingModelCatalogByProject: [String: [ModelInfo]] = [:]
    private var landingModelCatalogLoadingPaths: Set<String> = []
    private var landingModelCatalogGeneration = 0
    private var projectTrustTasks: [String: Task<Void, Error>] = [:]
    private var usageLimitTask: Task<Void, Never>?
    private var sessionUnloadTask: Task<Void, Never>?

    private let idleUnloadInterval: TimeInterval = 30 * 60
    private let maxLoadedIdleSessions = 3

    enum SidebarMode: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case files = "Files"
        var id: String { rawValue }
    }

    var selectedController: SessionController? {
        guard let selectedControllerID else { return nil }
        return controllers[selectedControllerID]
    }

    var activeComposerController: SessionController? {
        selectedController ?? (selectedControllerID == nil ? landingDraftController : nil)
    }

    var extensionPromptController: SessionController? {
        if let selectedController, selectedController.extensionUIPrompt != nil { return selectedController }
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

    var selectedUsageLimitProvider: UsageLimitProvider? {
        guard let controller = selectedController else { return nil }
        let selectedModel = controller.models.first { $0.id == controller.selectedModelID }
        return UsageLimitProvider.from(model: selectedModel)
    }

    var selectedProject: ProjectInfo? {
        guard let selectedProjectPath else { return nil }
        return projects.first { $0.path == selectedProjectPath }
    }

    func projectDisplayName(for path: String) -> String {
        projects.first { $0.path == path }?.displayName ?? URL(fileURLWithPath: path).lastPathComponent
    }

    func expandedDirectories(forProjectPath path: String) -> Set<String> {
        fileTreeExpandedByProject[path] ?? []
    }

    func setExpandedDirectories(_ expanded: Set<String>, forProjectPath path: String) {
        if expanded.isEmpty {
            fileTreeExpandedByProject.removeValue(forKey: path)
        } else {
            fileTreeExpandedByProject[path] = expanded
        }
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
        piMaintenance.onExtensionsUpdated = { [weak self] in
            Task { await self?.refreshSessionLaunchExtensions() }
        }
        piMaintenance.onModelsUpdated = { [weak self] in
            Task { await self?.refreshModelsAfterCatalogUpdate() }
        }
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
            async let launchExtensions: Void = self.refreshSessionLaunchExtensions()
            _ = await (customActions, namingModels, launchExtensions)

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
    }

    func refreshSessions() {
        sessionRefreshGeneration += 1
        let generation = sessionRefreshGeneration
        Task { [weak self] in
            guard let self else { return }
            let grouped = await SessionScanner.scan(maxAgeDays: SessionHistoryWindow.defaultDays)
            guard self.sessionRefreshGeneration == generation else { return }
            self.sessionsByProject = grouped
            self.syncOpenControllerTitles(from: grouped)

            var known = Dictionary(self.projects.map { ($0.path, $0) }, uniquingKeysWith: { existing, duplicate in
                existing.lastOpened >= duplicate.lastOpened ? existing : duplicate
            })
            let childOnlyProjectPaths = Set(grouped.compactMap { path, sessions in
                !sessions.isEmpty && sessions.allSatisfy(\.isChildSession) ? path : nil
            })
            for path in childOnlyProjectPaths {
                known.removeValue(forKey: path)
            }
            for path in grouped.keys where !childOnlyProjectPaths.contains(path) && known[path] == nil {
                known[path] = ProjectInfo(path: path, lastOpened: grouped[path]?.first?.timestamp ?? Date.distantPast)
            }
            self.projects = self.sortedProjects(Array(known.values), grouped: grouped)
            self.pruneFileTreeExpanded()
            self.saveRegistry()
        }
    }

    func loadSessionArchive() {
        guard sessionArchiveLoadState != .loading else { return }
        sessionArchiveLoadGeneration += 1
        let generation = sessionArchiveLoadGeneration
        sessionArchiveLoadState = .loading
        Task { [weak self] in
            guard let self else { return }
            let grouped = await SessionScanner.scanAll()
            guard self.sessionArchiveLoadGeneration == generation else { return }
            self.archivedSessionsByProject = grouped
            self.sessionArchiveLoadState = .loaded
            self.syncOpenControllerTitles(from: grouped)
        }
    }

    func addExistingProject() {
        Task { [weak self] in
            let urls = await ProjectDialogs.chooseProjectDirectories()
            guard let self else { return }
            let paths = urls.map { ProjectInfo(path: $0.path).path }
            guard let lastPath = paths.last else { return }

            let trustTasks = paths.map { (path: $0, task: self.addProject(path: $0)) }
            var lastProjectTrustFailed = false
            for item in trustTasks {
                do {
                    try await item.task.value
                    self.projectTrustTasks.removeValue(forKey: item.path)
                } catch {
                    if item.path == lastPath { lastProjectTrustFailed = true }
                    self.reportProjectTrustFailure(path: item.path, error: error)
                }
            }
            if !lastProjectTrustFailed {
                self.showNewChatHome(projectPath: lastPath)
            }
        }
    }

    func createProject() {
        Task { [weak self] in
            guard let self, let url = await ProjectDialogs.createProjectDirectoryURL() else { return }
            do {
                try await AsyncFileSystem.createDirectory(at: url)
                let path = ProjectInfo(path: url.path).path
                let trustTask = self.addProject(path: path)
                try await trustTask.value
                self.projectTrustTasks.removeValue(forKey: path)
                self.showNewChatHome(projectPath: path)
            } catch {
                if error is PiTrustService.ServiceError {
                    self.reportProjectTrustFailure(path: url.path, error: error)
                } else {
                    self.statusLine = "Could not create directory: \(error.localizedDescription)"
                }
            }
        }
    }

    @discardableResult
    func addProject(path: String) -> Task<Void, Error> {
        let project = ProjectInfo(path: path)
        if !projects.contains(where: { $0.path == project.path }) {
            projects.insert(project, at: 0)
        }
        touchProject(project.path)
        refreshSessions()
        let trustTask = Task { try await PiTrustService.trust(projectPath: project.path) }
        projectTrustTasks[project.path] = trustTask
        return trustTask
    }

    func toggleProjectPinned(_ path: String) {
        guard let index = projects.firstIndex(where: { $0.path == path }) else { return }
        projects[index].isPinned.toggle()
        if projects[index].isPinned {
            projects[index].pinnedSortIndex = (projects.filter(\.isPinned).map(\.pinnedSortIndex).max() ?? -1) + 1
        } else {
            projects[index].pinnedSortIndex = 0
        }
        normalizePinnedSortIndexes()
        sortProjectsInPlace()
        saveRegistry()
    }

    func selectProject(_ path: String) {
        showNewChatHome(projectPath: path)
    }

    func showNewChatHome(projectPath: String? = nil, quickChat: Bool = false) {
        let currentNormalProjectPath = selectedController.flatMap { $0.isQuickChat ? nil : $0.projectPath }
        let targetPath = projectPath ?? currentNormalProjectPath ?? selectedProjectPath.flatMap { path in
            isQuickChatsProject(path) ? nil : path
        } ?? projects.first?.path

        guard quickChat || targetPath != nil else {
            statusLine = "Add or select a project before starting a chat."
            return
        }
        if !quickChat, let targetPath, let trustTask = projectTrustTasks[targetPath] {
            statusLine = "Trusting project before opening it…"
            Task { [weak self] in
                do {
                    try await trustTask.value
                    guard let self, self.projectTrustTasks[targetPath] != nil else { return }
                    self.projectTrustTasks.removeValue(forKey: targetPath)
                    self.showNewChatHome(projectPath: targetPath)
                } catch {
                    self?.reportProjectTrustFailure(path: targetPath, error: error)
                }
            }
            return
        }

        selectedControllerID = nil
        composingQuickChat = quickChat
        selectedProjectPath = quickChat ? PiPaths.quickChatsProject.path : targetPath
        if let targetPath, !quickChat { touchProject(targetPath) }
        prepareLandingDraft()
        newChatHomeRequestID += 1
    }

    func prepareLandingDraft() {
        guard selectedControllerID == nil, let selectedProjectPath else { return }
        let quickChat = composingQuickChat || isQuickChatsProject(selectedProjectPath)
        if let existing = landingDraftController,
           existing.projectPath == selectedProjectPath,
           existing.isQuickChat == quickChat {
            loadLandingSlashCommands(for: existing)
            return
        }
        let previous = landingDraftController
        previous?.stopRPC()
        let controller = SessionController(
            projectPath: selectedProjectPath,
            sessionPath: nil,
            title: quickChat ? "Quick Chat" : "Untitled",
            messages: [],
            kind: quickChat ? .quickChat : .persistent
        ) { [weak self] event in
            self?.handleControllerEvent(event)
        }
        if let previous {
            controller.setLandingResources(previous.chatResources)
            if let level = previous.explicitThinkingLevel { controller.setThinkingLevel(level) }
        }
        pendingLandingModelSelection = previous?.explicitModelSelectionID.map { (controller.id, $0) }
            ?? pendingLandingModelSelection.flatMap { pending in
                // A previous transfer may still be waiting for the destination catalog.
                previous?.id == pending.controllerID ? (controller.id, pending.modelID) : nil
            }
        let initialModels = landingModelCatalogByProject[selectedProjectPath] ?? sessionNamingModels
        if !initialModels.isEmpty {
            applyLandingModels(initialModels, to: controller)
        }
        landingDraftController = controller
        loadLandingSlashCommands(for: controller)
    }

    func invalidateSlashCommandCatalog() {
        slashCommandCatalogGeneration += 1
        slashCommandCatalogByProject.removeAll()
        slashCommandCatalogLoadingPaths.removeAll()
        landingModelCatalogGeneration += 1
        landingModelCatalogByProject.removeAll()
        landingModelCatalogLoadingPaths.removeAll()
        if let landingDraftController {
            landingDraftController.slashCommands = []
            landingDraftController.hasCompleteModelCatalog = false
            loadLandingSlashCommands(for: landingDraftController)
        }
    }

    func updateLandingResources(_ items: [PiResourceItem], for controller: SessionController) {
        guard landingDraftController?.id == controller.id else { return }
        let previousIDs = controller.chatResources.map(\.id)
        controller.setLandingResources(items)
        guard controller.chatResources.map(\.id) != previousIDs else { return }
        controller.slashCommands = []
        loadLandingSlashCommands(for: controller)
    }

    private func loadLandingSlashCommands(for controller: SessionController) {
        let projectPath = controller.projectPath
        let additions = controller.chatResources
        let commandKey = LandingCommandKey(projectPath: projectPath, resourceIDs: additions.map(\.id).sorted())
        let cachedCommands = slashCommandCatalogByProject[commandKey]
        let cachedModels = landingModelCatalogByProject[projectPath]
        if let cachedCommands { controller.slashCommands = cachedCommands }
        if let cachedModels {
            applyLandingModels(cachedModels, to: controller)
            controller.hasCompleteModelCatalog = true
        }

        let loadsCommands = cachedCommands == nil && slashCommandCatalogLoadingPaths.insert(commandKey).inserted
        let loadsModels = cachedModels == nil && landingModelCatalogLoadingPaths.insert(projectPath).inserted
        if cachedModels == nil { controller.isDiscoveringModels = true }
        guard loadsCommands || loadsModels else { return }
        let commandGeneration = slashCommandCatalogGeneration
        let modelGeneration = landingModelCatalogGeneration

        Task { [weak self] in
            let client = PiRPCClient(projectPath: projectPath, noSession: true, launchResources: PiLaunchResources(items: additions))
            var commands: [SlashCommandInfo] = []
            var discoveredModels: [ModelInfo]?
            do {
                try await client.start()
                if loadsModels,
                   let response = try? await client.command(["type": "get_available_models"]),
                   let data = response["data"] as? [String: Any],
                   let modelDicts = data["models"] as? [[String: Any]] {
                    let parsed = modelDicts.compactMap(ModelInfo.from)
                    if parsed.count == modelDicts.count {
                        // Cached unscoped; EnabledModelScope is applied fresh in
                        // applyLandingModels so scope edits never go stale here.
                        discoveredModels = parsed.sorted {
                            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                        }
                    }
                }
                if loadsCommands,
                   let response = try? await client.command(["type": "get_commands"]),
                   let data = response["data"] as? [String: Any],
                   let commandDicts = data["commands"] as? [[String: Any]] {
                    commands = commandDicts.compactMap(SlashCommandInfo.fromRPC)
                }
            } catch {
                // Seeded model and built-in command fallbacks remain usable; failed model discovery is not cached.
            }
            client.stop()

            guard let self else { return }
            let currentLanding = self.landingDraftController.flatMap {
                $0.projectPath == projectPath ? $0 : nil
            }
            if loadsCommands, self.slashCommandCatalogGeneration == commandGeneration {
                self.slashCommandCatalogLoadingPaths.remove(commandKey)
                self.slashCommandCatalogByProject[commandKey] = commands
                if currentLanding?.chatResources.map(\.id).sorted() == commandKey.resourceIDs {
                    currentLanding?.slashCommands = commands
                }
            }
            if loadsModels, self.landingModelCatalogGeneration == modelGeneration {
                self.landingModelCatalogLoadingPaths.remove(projectPath)
                if let discoveredModels {
                    self.landingModelCatalogByProject[projectPath] = discoveredModels
                    if let currentLanding {
                        self.applyLandingModels(discoveredModels, to: currentLanding)
                        currentLanding.hasCompleteModelCatalog = true
                    }
                }
                currentLanding?.isDiscoveringModels = false
            }
        }
    }

    private func applyLandingModels(_ models: [ModelInfo], to controller: SessionController) {
        let scoped = EnabledModelScope.scopedModels(models, projectPath: controller.projectPath)
        let currentSelection = controller.selectedModelID
        controller.models = scoped
        if let pending = pendingLandingModelSelection, pending.controllerID == controller.id,
           landingModelCatalogByProject[controller.projectPath] != nil {
            pendingLandingModelSelection = nil
            if controller.explicitModelSelectionID == nil,
               scoped.contains(where: { $0.id == pending.modelID }) {
                controller.setModel(pending.modelID)
                return
            }
        }
        if !currentSelection.isEmpty { return }
        controller.selectedModelID = DefaultModelSchedule.effectiveModelID() ?? ""
    }

    private func refreshLandingModelDefaults() {
        landingDraftController?.refreshNewSessionDefaults()
    }

    func activateLandingDraft(_ controller: SessionController) {
        guard landingDraftController?.id == controller.id else { return }
        pendingLandingModelSelection = nil
        landingDraftText = ""
        landingDraftImages = []
        touchProject(controller.projectPath)
        controllers[controller.id] = controller
        addControllerToInbox(controller)
        selectedProjectPath = controller.projectPath
        selectedControllerID = controller.id
        composingQuickChat = false
        finishedUnseenControllerIDs.remove(controller.id)
        landingDraftController = nil
    }

    func recentSessions(forProjectPath projectPath: String, limit: Int) -> [SessionSummary] {
        let sessions = sessionsByProject[projectPath] ?? []
        let byPath = Dictionary(uniqueKeysWithValues: sessions.map { ($0.filePath, $0) })
        var result: [SessionSummary] = []
        var seen = Set<String>()
        for session in sessions {
            let candidate: SessionSummary
            if session.isChildSession, let parentPath = session.parentSessionPath, let parent = byPath[parentPath] {
                candidate = parent
            } else {
                candidate = session
            }
            guard !seen.contains(candidate.filePath) else { continue }
            seen.insert(candidate.filePath)
            result.append(candidate)
            if result.count >= limit { break }
        }
        return result
    }

    func inboxID(forSessionPath path: String) -> String {
        "session:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }

    func inboxID(for controller: SessionController) -> String {
        if let sessionPath = controller.sessionPath { return inboxID(forSessionPath: sessionPath) }
        return "controller:\(controller.id)"
    }

    func inboxController(for itemID: String) -> SessionController? {
        if itemID.hasPrefix("controller:") {
            return controllers[String(itemID.dropFirst("controller:".count))]
        }
        guard let path = sessionPath(fromInboxID: itemID) else { return nil }
        return controller(forSessionPath: path)
    }

    func inboxSummary(for itemID: String) -> SessionSummary? {
        guard let path = sessionPath(fromInboxID: itemID) else { return nil }
        return sessionSummary(forPath: path)
    }

    func inboxParentID(for itemID: String) -> String? {
        guard let parentPath = inboxSummary(for: itemID)?.parentSessionPath else { return nil }
        return inboxID(forSessionPath: parentPath)
    }

    func isQuickChatInboxItem(_ itemID: String) -> Bool {
        if let controller = inboxController(for: itemID) { return controller.isQuickChat }
        guard let summary = inboxSummary(for: itemID) else { return false }
        return isQuickChatsProject(summary.projectPath)
    }

    var canUndoInboxDismissal: Bool { inboxDismissalUndo != nil }

    var inboxDismissalUndoTitle: String? { inboxDismissalUndo?.title }

    func markInboxItemDone(_ itemID: String) {
        let removedIDs: Set<String>
        if inboxParentID(for: itemID) == nil {
            removedIDs = Set([itemID] + sessionInboxIDs.filter { inboxParentID(for: $0) == itemID })
        } else {
            removedIDs = [itemID]
        }
        guard !removedIDs.contains(where: { inboxController(for: $0)?.showsActivityIndicator == true }) else {
            statusLine = "A working session cannot be marked done."
            return
        }

        let removedItems = sessionInboxIDs.enumerated().compactMap { index, id in
            removedIDs.contains(id) ? (id: id, index: index) : nil
        }
        guard !removedItems.isEmpty else { return }
        let removedControllers = controllers.values.filter { controller in
            removedIDs.contains(inboxID(for: controller)) || removedIDs.contains("controller:\(controller.id)")
        }
        let removedSelectedControllerID = selectedController.flatMap { controller -> String? in
            let selectedIDs = Set([inboxID(for: controller), "controller:\(controller.id)"])
            return removedIDs.isDisjoint(with: selectedIDs) ? nil : controller.id
        }
        let title = inboxController(for: itemID)?.title ?? inboxSummary(for: itemID)?.title ?? "Thread"
        inboxDismissalUndo = InboxDismissalUndo(
            items: removedItems,
            selectedControllerID: removedSelectedControllerID,
            title: title.isEmpty ? "Untitled" : title
        )
        sessionInboxIDs.removeAll { removedIDs.contains($0) }
        for controller in removedControllers {
            controller.suspendRuntime()
            finishedUnseenControllerIDs.remove(controller.id)
            activeControllerIDs.remove(controller.id)
        }

        if removedSelectedControllerID != nil {
            selectedControllerID = nil
            composingQuickChat = false
            newChatHomeRequestID += 1
        }
    }

    func undoLastInboxDismissal() {
        guard let undo = inboxDismissalUndo else { return }
        for item in undo.items.sorted(by: { $0.index < $1.index }) where !sessionInboxIDs.contains(item.id) {
            sessionInboxIDs.insert(item.id, at: min(item.index, sessionInboxIDs.endIndex))
        }
        if let controllerID = undo.selectedControllerID, let controller = controllers[controllerID] {
            selectedControllerID = controllerID
            selectedProjectPath = controller.projectPath
            composingQuickChat = false
        }
        inboxDismissalUndo = nil
        statusLine = "Restored: \(undo.title)"
    }

    func moveInboxItem(_ draggedID: String, relativeTo targetID: String, after: Bool) {
        guard draggedID != targetID,
              sessionInboxIDs.contains(draggedID),
              sessionInboxIDs.contains(targetID) else { return }

        let draggedParent = inboxParentID(for: draggedID)
        let targetParent = inboxParentID(for: targetID)
        if draggedParent != nil || targetParent != nil {
            guard draggedParent == targetParent, draggedParent != nil else { return }
            sessionInboxIDs.removeAll { $0 == draggedID }
            guard let targetIndex = sessionInboxIDs.firstIndex(of: targetID) else { return }
            sessionInboxIDs.insert(draggedID, at: targetIndex + (after ? 1 : 0))
            return
        }

        let moving = sessionInboxIDs.filter { $0 == draggedID || inboxParentID(for: $0) == draggedID }
        sessionInboxIDs.removeAll { moving.contains($0) }
        guard let targetIndex = sessionInboxIDs.firstIndex(of: targetID) else {
            sessionInboxIDs.append(contentsOf: moving)
            return
        }
        let targetChildren = sessionInboxIDs.filter { inboxParentID(for: $0) == targetID }
        let insertionIndex = after ? targetIndex + 1 + targetChildren.count : targetIndex
        sessionInboxIDs.insert(contentsOf: moving, at: min(insertionIndex, sessionInboxIDs.endIndex))
    }

    @discardableResult
    func newSession(projectPath: String, extensionPaths: [String] = [], initialMessage: String? = nil) -> SessionController {
        landingDraftController?.stopRPC()
        landingDraftController = nil
        touchProject(projectPath)
        selectedProjectPath = projectPath
        composingQuickChat = false
        let controller = SessionController(
            projectPath: projectPath,
            sessionPath: nil,
            title: "Untitled",
            messages: [],
            extensionPaths: extensionPaths
        ) { [weak self] event in
            self?.handleControllerEvent(event)
        }
        controllers[controller.id] = controller
        addControllerToInbox(controller)
        selectedControllerID = controller.id
        finishedUnseenControllerIDs.remove(controller.id)
        let trustTask = projectTrustTasks[projectPath]
        Task {
            if let trustTask {
                do {
                    try await trustTask.value
                    self.projectTrustTasks.removeValue(forKey: projectPath)
                } catch {
                    controller.errorText = error.localizedDescription
                    self.reportProjectTrustFailure(path: projectPath, error: error)
                    return
                }
            }
            do {
                try await controller.ensureRPC(reloadMessages: false)
                if let initialMessage { await controller.send(initialMessage) }
            } catch {
                self.statusLine = error.localizedDescription
            }
        }
        return controller
    }

    func newQuickChat(extensionPaths: [String] = [], initialMessage: String? = nil) {
        landingDraftController?.stopRPC()
        landingDraftController = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await AsyncFileSystem.createDirectory(at: PiPaths.quickChatsProject)
            } catch {
                self.statusLine = "Could not create Quick Chats directory: \(error.localizedDescription)"
                return
            }

            let projectPath = PiPaths.quickChatsProject.path
            let controller = SessionController(
                projectPath: projectPath,
                sessionPath: nil,
                title: "Quick Chat",
                messages: [],
                kind: .quickChat,
                extensionPaths: extensionPaths
            ) { [weak self] event in
                self?.handleControllerEvent(event)
            }
            self.controllers[controller.id] = controller
            self.selectedProjectPath = projectPath
            self.composingQuickChat = false
            self.addControllerToInbox(controller)
            self.selectedControllerID = controller.id
            self.finishedUnseenControllerIDs.remove(controller.id)
            do {
                try await controller.ensureRPC(reloadMessages: false)
                if let initialMessage { await controller.send(initialMessage) }
            } catch {
                self.statusLine = error.localizedDescription
            }
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

    func updateSessionLaunchExtensions(from resources: [PiResourceItem]) {
        sessionLaunchExtensions = resources
            .filter { $0.type == "extensions" && !$0.enabled }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func refreshSessionLaunchExtensions() async {
        guard let resources = try? await PiResourceService.list() else { return }
        updateSessionLaunchExtensions(from: resources)
    }

    private func select(_ controller: SessionController) {
        controller.resumeRuntimeLoading()
        touchProject(controller.projectPath)
        selectedProjectPath = controller.projectPath
        composingQuickChat = false
        addControllerToInbox(controller)
        selectedControllerID = controller.id
        finishedUnseenControllerIDs.remove(controller.id)
    }

    func selectController(_ controller: SessionController) {
        landingDraftController?.stopRPC()
        landingDraftController = nil
        select(controller)
        Task { try? await controller.ensureRPC(reloadMessages: false) }
    }

    /// Registers a controller for a saved session and loads its transcript from
    /// disk. The caller selects it; the transcript is applied only if it is
    /// still selected when parsing finishes.
    private func makeController(for summary: SessionSummary) -> SessionController {
        let controller = SessionController(
            projectPath: summary.projectPath,
            sessionPath: summary.filePath,
            title: summary.title,
            messages: [],
            kind: isQuickChatsProject(summary.projectPath) ? .quickChat : .persistent
        ) { [weak self] event in
            self?.handleControllerEvent(event)
        }
        controllers[controller.id] = controller
        Task {
            if let parsed = await SessionParser.parseFileAsync(URL(fileURLWithPath: summary.filePath)), selectedControllerID == controller.id {
                await MarkdownPrewarmer.warm(parsed.messages, theme: selectedTheme)
                controller.messages = parsed.messages
                controller.bottomScrollRequest += 1
            }
        }
        return controller
    }

    private func prepareToOpen(_ summary: SessionSummary) {
        touchProject(summary.projectPath)
        selectedProjectPath = summary.projectPath
        composingQuickChat = false
        addSessionToInbox(summary)
    }

    func selectSession(_ summary: SessionSummary) {
        landingDraftController?.stopRPC()
        landingDraftController = nil
        prepareToOpen(summary)
        if let existing = controller(forSessionPath: summary.filePath) {
            selectController(existing)
            return
        }
        let controller = makeController(for: summary)
        selectedControllerID = controller.id
        Task {
            do { try await controller.ensureRPC(reloadMessages: false) }
            catch { statusLine = error.localizedDescription }
        }
    }

    func reconnect(_ controller: SessionController) {
        select(controller)
        Task { [weak self] in
            do {
                try await controller.ensureRPC()
                self?.enforceLoadedSessionLimit()
            } catch {
                self?.statusLine = error.localizedDescription
            }
        }
    }

    func reconnectSession(_ summary: SessionSummary) {
        prepareToOpen(summary)
        reconnect(controller(forSessionPath: summary.filePath) ?? makeController(for: summary))
    }

    func unload(_ controller: SessionController) {
        if controller.isQuickChat {
            closeQuickChat(controller)
            return
        }
        guard !controller.showsActivityIndicator else {
            statusLine = "Cannot unload a working session. Abort or wait for it to finish."
            return
        }
        guard controller.isProcessActive else {
            statusLine = "Session already unloaded."
            return
        }
        controller.stopRPC()
        statusLine = "Unloaded: \(controller.title.isEmpty ? "Untitled" : controller.title)"
    }

    func closeQuickChat(_ controller: SessionController) {
        guard controller.isQuickChat else { return }
        guard !controller.showsActivityIndicator else {
            statusLine = "Cannot close a working quick chat. Abort or wait for it to finish."
            return
        }
        removeController(controller)
        if selectedControllerID == controller.id {
            selectedControllerID = controllers.values.sorted { $0.lastRuntimeUse > $1.lastRuntimeUse }.first?.id
            selectedProjectPath = selectedController?.projectPath
        }
        statusLine = "Closed quick chat."
    }

    func closeOtherQuickChats(keeping controller: SessionController?) {
        var count = 0
        for item in quickChatControllers where item.id != controller?.id && !item.showsActivityIndicator {
            removeController(item)
            count += 1
        }
        statusLine = "Closed \(count) quick chat\(count == 1 ? "" : "s")."
    }

    func closeAllQuickChats() {
        var count = 0
        for item in quickChatControllers where !item.showsActivityIndicator {
            removeController(item)
            count += 1
        }
        if let selectedControllerID, controllers[selectedControllerID] == nil {
            self.selectedControllerID = controllers.values.sorted { $0.lastRuntimeUse > $1.lastRuntimeUse }.first?.id
            selectedProjectPath = selectedController?.projectPath
        }
        statusLine = "Closed \(count) quick chat\(count == 1 ? "" : "s")."
    }

    private func removeController(_ controller: SessionController, removeInbox: Bool = true) {
        let itemID = removeInbox ? inboxID(for: controller) : nil
        controller.stopRPC()
        controllers.removeValue(forKey: controller.id)
        if let itemID {
            sessionInboxIDs.removeAll { $0 == itemID || $0 == "controller:\(controller.id)" }
        }
        finishedUnseenControllerIDs.remove(controller.id)
        activeControllerIDs.remove(controller.id)
    }

    func unloadSession(path: String) {
        guard let controller = controller(forSessionPath: path) else {
            statusLine = "Session is not loaded."
            return
        }
        unload(controller)
    }

    func requestSessionRename(_ controller: SessionController) {
        guard let path = controller.sessionPath, !controller.showsActivityIndicator else { return }
        sessionPendingRename = SessionRenameRequest(filePath: path, title: controller.title)
    }

    func requestSessionRename(_ summary: SessionSummary) {
        guard activeController(forSessionPath: summary.filePath) == nil else { return }
        sessionPendingRename = SessionRenameRequest(filePath: summary.filePath, title: summary.title)
    }

    func renameSession(_ request: SessionRenameRequest, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let path = request.filePath
        guard activeController(forSessionPath: path) == nil else {
            statusLine = "Cannot rename a working session."
            return
        }
        let controller = controller(forSessionPath: path)
        if let controller, controller.hasRuntimeOrStartup {
            Task {
                if await controller.renameSession(name) {
                    refreshSessions()
                    if sessionArchiveLoadState == .loaded { loadSessionArchive() }
                }
            }
            return
        }
        do {
            try appendSessionName(name, to: path)
            controller?.title = name
            renameSummary(in: &sessionsByProject, path: path, to: name)
            renameSummary(in: &archivedSessionsByProject, path: path, to: name)
            refreshSessions()
            statusLine = "Session renamed: \(name)"
        } catch {
            statusLine = "Could not rename session: \(error.localizedDescription)"
        }
    }

    private func renameSummary(in grouped: inout [String: [SessionSummary]], path: String, to name: String) {
        for project in grouped.keys {
            if let index = grouped[project]?.firstIndex(where: { $0.filePath == path }) {
                grouped[project]?[index].title = name
                grouped[project]?[index].named = true
            }
        }
    }

    private func appendSessionName(_ name: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let first = lines.first,
              let header = try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              header["type"] as? String == "session",
              let last = lines.last,
              let entry = try JSONSerialization.jsonObject(with: Data(last)) as? [String: Any],
              let parentID = entry["id"] as? String else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let timestamp = ISO8601DateFormatter()
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let info: [String: String] = [
            "type": "session_info", "id": String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)),
            "parentId": parentID, "timestamp": timestamp.string(from: Date()), "name": name
        ]
        let encoded = try JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if data.last != 0x0A { try handle.write(contentsOf: Data([0x0A])) }
        try handle.write(contentsOf: encoded + Data([0x0A]))
    }

    func requestSessionDeletion(_ summary: SessionSummary) {
        requestSessionDeletion(
            filePath: summary.filePath,
            projectPath: summary.projectPath,
            title: summary.title
        )
    }

    func requestSessionDeletion(_ controller: SessionController) {
        guard let filePath = controller.sessionPath else {
            statusLine = "This session has not been saved yet."
            return
        }
        requestSessionDeletion(filePath: filePath, projectPath: controller.projectPath, title: controller.title)
    }

    func deleteSession(_ request: SessionDeletionRequest) {
        sessionPendingDeletion = nil
        if let controller = controller(forSessionPath: request.filePath), controller.showsActivityIndicator {
            statusLine = "Cannot delete a working session. Abort or wait for it to finish."
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let url = URL(fileURLWithPath: request.filePath)
                let fileExists = await AsyncFileSystem.itemExists(at: url)
                if fileExists {
                    try await AsyncFileSystem.moveToTrash(url)
                }
                if let controller = self.controller(forSessionPath: request.filePath) {
                    self.removeController(controller, removeInbox: false)
                    if self.selectedControllerID == controller.id {
                        self.selectedControllerID = nil
                        self.selectedProjectPath = request.projectPath
                    }
                }
                let deletedInboxID = self.inboxID(forSessionPath: request.filePath)
                self.sessionInboxIDs.removeAll { $0 == deletedInboxID || self.inboxParentID(for: $0) == deletedInboxID }
                self.sessionsByProject[request.projectPath]?.removeAll { $0.filePath == request.filePath }
                self.archivedSessionsByProject[request.projectPath]?.removeAll { $0.filePath == request.filePath }
                let title = request.title.isEmpty ? "Untitled" : request.title
                self.statusLine = fileExists ? "Moved to Trash: \(title)" : "Closed unsaved session: \(title)"
                self.refreshSessions()
                if self.sessionArchiveLoadState == .loaded { self.loadSessionArchive() }
            } catch {
                self.statusLine = "Could not move session to Trash: \(error.localizedDescription)"
            }
        }
    }

    private func requestSessionDeletion(filePath: String, projectPath: String, title: String) {
        if let controller = controller(forSessionPath: filePath), controller.showsActivityIndicator {
            statusLine = "Cannot delete a working session. Abort or wait for it to finish."
            return
        }
        sessionPendingDeletion = SessionDeletionRequest(
            filePath: filePath,
            projectPath: projectPath,
            title: title
        )
    }

    func unloadOtherSessions(keeping controller: SessionController?) {
        var count = 0
        for item in controllers.values where item.id != controller?.id && item.isProcessActive && !item.showsActivityIndicator {
            item.stopRPC()
            count += 1
        }
        statusLine = "Unloaded \(count) idle session\(count == 1 ? "" : "s")."
    }

    func unloadAllIdleSessions(includeSelected: Bool = true) {
        var count = 0
        for item in controllers.values where item.isProcessActive && !item.showsActivityIndicator {
            if !includeSelected, item.id == selectedControllerID { continue }
            item.stopRPC()
            count += 1
        }
        statusLine = "Unloaded \(count) idle session\(count == 1 ? "" : "s")."
    }

    var canReloadCurrentSessionRuntime: Bool {
        guard let selectedController else { return false }
        return canReloadSessionRuntime(selectedController)
    }

    var canReloadAnyIdleSessionRuntime: Bool {
        controllers.values.contains { isIdlePersistentRuntime($0) }
    }

    private func isIdlePersistentRuntime(_ controller: SessionController) -> Bool {
        !controller.isQuickChat && controller.isProcessActive && !controller.showsActivityIndicator
    }

    func canReloadSessionRuntime(_ controller: SessionController?) -> Bool {
        guard let controller else { return false }
        return isIdlePersistentRuntime(controller)
    }

    func controller(forSessionPath path: String) -> SessionController? {
        controllers.values.first { $0.sessionPath == path }
    }

    func loadedController(forSessionPath path: String) -> SessionController? {
        controllers.values.first { $0.sessionPath == path && $0.isProcessActive }
    }

    func reloadCurrentSessionRuntime() {
        guard canReloadCurrentSessionRuntime, let selectedController else { return }
        reloadSessionRuntime(selectedController)
    }

    func reloadSessionRuntime(_ controller: SessionController) {
        guard canReloadSessionRuntime(controller) else {
            statusLine = "Cannot reload this session runtime."
            return
        }
        Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            do {
                try await controller.reloadRuntime()
                self.statusLine = "Reloaded: \(controller.title.isEmpty ? "Untitled" : controller.title)"
            } catch {
                self.statusLine = error.localizedDescription
            }
        }
    }

    func reloadSessionRuntime(path: String) {
        guard let controller = loadedController(forSessionPath: path) else {
            statusLine = "Session runtime is not loaded."
            return
        }
        reloadSessionRuntime(controller)
    }

    func reloadAllIdleSessionRuntimes() {
        let candidates = controllers.values.filter { isIdlePersistentRuntime($0) }
        let skipped = controllers.values.filter { !$0.isQuickChat && $0.isProcessActive && $0.showsActivityIndicator }.count
        guard !candidates.isEmpty else {
            statusLine = skipped > 0 ? "No idle session runtimes to reload; \(skipped) working." : "No loaded session runtimes to reload."
            return
        }
        Task { [weak self] in
            guard let self else { return }
            var reloaded = 0
            for controller in candidates {
                do {
                    try await controller.reloadRuntime()
                    reloaded += 1
                } catch {
                    self.statusLine = error.localizedDescription
                }
            }
            self.statusLine = "Reloaded \(reloaded) idle session runtime\(reloaded == 1 ? "" : "s")\(skipped > 0 ? "; skipped \(skipped) working" : "")."
        }
    }

    private func refreshModelsAfterCatalogUpdate() async {
        landingModelCatalogGeneration += 1
        landingModelCatalogByProject.removeAll()
        landingModelCatalogLoadingPaths.removeAll()
        if let landingDraftController {
            landingDraftController.hasCompleteModelCatalog = false
            loadLandingSlashCommands(for: landingDraftController)
        }
        await loadSessionNamingModels()

        let candidates = controllers.values.filter { isIdlePersistentRuntime($0) }
        let working = controllers.values.filter { !$0.isQuickChat && $0.isProcessActive && $0.showsActivityIndicator }.count
        guard !candidates.isEmpty else {
            statusLine = working > 0
                ? "Model catalogs refreshed. Reload working session runtimes after they settle to load new models."
                : "Model catalogs refreshed. New models will load when session runtimes reconnect."
            return
        }

        var reloaded = 0
        var failed = 0
        for controller in candidates {
            do {
                try await controller.reloadRuntime()
                reloaded += 1
            } catch {
                failed += 1
            }
        }
        var status = "Model catalogs refreshed; reloaded \(reloaded) idle session runtime\(reloaded == 1 ? "" : "s")."
        if working > 0 { status += " Reload \(working) working runtime\(working == 1 ? "" : "s") after they settle." }
        if failed > 0 { status += " \(failed) runtime\(failed == 1 ? "" : "s") could not be reloaded." }
        statusLine = status
    }

    func activeController(forSessionPath path: String) -> SessionController? {
        controllers.values.first { $0.sessionPath == path && $0.showsActivityIndicator }
    }

    func activeController(forProjectPath path: String) -> SessionController? {
        controllers.values.first { $0.projectPath == path && $0.showsActivityIndicator }
    }

    func finishedUnseen(_ controller: SessionController) -> Bool {
        finishedUnseenControllerIDs.contains(controller.id)
    }

    func finishedUnseen(forSessionPath path: String) -> Bool {
        controllers.values.contains { $0.sessionPath == path && finishedUnseenControllerIDs.contains($0.id) }
    }

    func shutdown() {
        usageLimitTask?.cancel()
        usageLimitTask = nil
        sessionUnloadTask?.cancel()
        sessionUnloadTask = nil
        for controller in controllers.values {
            controller.stopRPC()
        }
    }

    func runCustomAction(_ action: CustomAction) {
        guard let selectedController else {
            statusLine = "Select a session before running a custom action."
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
            statusLine = "Select a session before editing custom actions."
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

    func usageLimit(for provider: UsageLimitProvider?) -> UsageLimitSnapshot? {
        guard let provider else { return nil }
        return usageLimits[provider]
    }

    func refreshUsageLimit(for provider: UsageLimitProvider?) {
        guard let provider else { return }
        Task { [weak self] in
            _ = await PiEnvironment.mergedAsync()
            let snapshot = await UsageLimitService.fetch(provider)
            self?.usageLimits[provider] = snapshot
        }
    }

    private func startUsageLimitPolling() {
        usageLimitTask?.cancel()
        usageLimitTask = Task { [weak self] in
            _ = await PiEnvironment.mergedAsync()
            while !Task.isCancelled {
                if let provider = self?.selectedUsageLimitProvider {
                    let snapshot = await UsageLimitService.fetch(provider)
                    guard !Task.isCancelled else { break }
                    self?.usageLimits[provider] = snapshot
                    try? await Task.sleep(nanoseconds: 300_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                }
            }
        }
    }

    private func startSessionUnloadPolling() {
        sessionUnloadTask?.cancel()
        sessionUnloadTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { break }
                self?.enforceSessionUnloadPolicy()
            }
        }
    }

    private func enforceSessionUnloadPolicy() {
        guard sessionRuntimePolicy == .hybrid else { return }
        let now = Date()
        for controller in unloadCandidates(includeSelected: false) where now.timeIntervalSince(controller.lastRuntimeUse) >= idleUnloadInterval {
            controller.stopRPC()
        }
        enforceLoadedSessionLimit()
    }

    private func enforceLoadedSessionLimit() {
        guard sessionRuntimePolicy == .hybrid else { return }
        let candidates = unloadCandidates(includeSelected: false).sorted { $0.lastRuntimeUse < $1.lastRuntimeUse }
        let overflow = candidates.count - maxLoadedIdleSessions
        guard overflow > 0 else { return }
        for controller in candidates.prefix(overflow) {
            controller.stopRPC()
        }
    }

    private func unloadCandidates(includeSelected: Bool) -> [SessionController] {
        controllers.values.filter { controller in
            controller.isProcessActive &&
            !controller.isQuickChat &&
            !controller.showsActivityIndicator &&
            !finishedUnseenControllerIDs.contains(controller.id) &&
            (includeSelected || controller.id != selectedControllerID)
        }
    }

    func isQuickChatsProject(_ path: String) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path == PiPaths.quickChatsProject.standardizedFileURL.path
    }

    private func sessionPath(fromInboxID itemID: String) -> String? {
        guard itemID.hasPrefix("session:") else { return nil }
        return String(itemID.dropFirst("session:".count))
    }

    private func sessionSummary(forPath path: String) -> SessionSummary? {
        for sessions in sessionsByProject.values {
            if let summary = sessions.first(where: { $0.filePath == path }) { return summary }
        }
        for sessions in archivedSessionsByProject.values {
            if let summary = sessions.first(where: { $0.filePath == path }) { return summary }
        }
        return nil
    }

    private func appendInboxID(_ itemID: String) {
        guard !sessionInboxIDs.contains(itemID) else { return }
        sessionInboxIDs.append(itemID)
    }

    private func addControllerToInbox(_ controller: SessionController) {
        let currentID = inboxID(for: controller)
        let transientID = "controller:\(controller.id)"
        if currentID != transientID, let transientIndex = sessionInboxIDs.firstIndex(of: transientID) {
            if !sessionInboxIDs.contains(currentID) {
                sessionInboxIDs[transientIndex] = currentID
            } else {
                sessionInboxIDs.remove(at: transientIndex)
            }
            return
        }
        appendInboxID(currentID)
    }

    private func addSessionToInbox(_ summary: SessionSummary) {
        if summary.isChildSession,
           let parentPath = summary.parentSessionPath,
           let parent = sessionSummary(forPath: parentPath) {
            appendInboxID(inboxID(forSessionPath: parent.filePath))
        }
        appendInboxID(inboxID(forSessionPath: summary.filePath))
    }

    private func syncControllerInboxID(_ controller: SessionController) {
        guard controller.sessionPath != nil else { return }
        let transientID = "controller:\(controller.id)"
        let stableID = inboxID(for: controller)
        guard sessionInboxIDs.contains(transientID) || sessionInboxIDs.contains(stableID) else { return }
        addControllerToInbox(controller)
    }

    private func syncOpenControllerTitles(from grouped: [String: [SessionSummary]]) {
        let summariesByPath = Dictionary(uniqueKeysWithValues: grouped.values.flatMap { $0 }.map { ($0.filePath, $0) })
        for controller in controllers.values {
            guard let sessionPath = controller.sessionPath,
                  let summary = summariesByPath[sessionPath],
                  summary.title != controller.title,
                  summary.named || controller.title.isEmpty || controller.title == "Untitled" else { continue }
            controller.title = summary.title
        }
    }

    private func handleControllerEvent(_ event: SessionController.Event) {
        switch event {
        case .sessionFileChanged:
            for controller in controllers.values { syncControllerInboxID(controller) }
            refreshSessions()
        case .titleChanged:
            refreshSessions()
        case .activityChanged:
            reconcileControllerActivity()
            // Sidebar sections derive attention/loaded state from controller
            // properties this model does not publish itself.
            objectWillChange.send()
        case .sessionsChanged:
            refreshSessions()
        case .showSessionTree:
            showingSessionTree = true
        case .showPiUpdates(let cwd, let projectName, let action):
            piMaintenance.presentUpdates(cwd: cwd, projectName: projectName, requestedAction: action)
        case .showPiChangelog:
            piMaintenance.openChangelog()
        case .unloadOthers(let controllerID):
            unloadOtherSessions(keeping: controllers[controllerID])
        case .unloadAllIdle:
            unloadAllIdleSessions()
        case .extensionUIChanged:
            objectWillChange.send()
        case .log(let message):
            if !message.isEmpty { statusLine = message.oneLine(max: 160) }
        }
    }

    private func reconcileControllerActivity() {
        let activeControllers = controllers.values.filter(\.showsActivityIndicator)
        for controller in activeControllers { addControllerToInbox(controller) }
        let currentActiveIDs = Set(activeControllers.map(\.id))
        let finishedIDs = activeControllerIDs.subtracting(currentActiveIDs)
        let backgroundFinishedIDs: Set<String>
        if let selectedControllerID {
            backgroundFinishedIDs = finishedIDs.filter { $0 != selectedControllerID }
        } else {
            backgroundFinishedIDs = finishedIDs
        }
        finishedUnseenControllerIDs.formUnion(backgroundFinishedIDs)
        let notificationIDs = NSApp.isActive ? backgroundFinishedIDs : finishedIDs
        for controllerID in notificationIDs {
            notifyAgentFinished(controllerID: controllerID)
        }
        activeControllerIDs = currentActiveIDs
    }

    func setExtensionStatusHidden(_ key: String, hidden: Bool) {
        if hidden {
            hiddenExtensionStatusKeys.insert(key)
        } else {
            hiddenExtensionStatusKeys.remove(key)
        }
    }

    func scheduleTestNotification(delay: TimeInterval = 10) {
        guard notificationsEnabled else {
            statusLine = "Notifications are disabled."
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "PiG notification test"
        content.body = "Notifications are working."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "PiG.testNotification.\(UUID().uuidString)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)
        )
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Task { @MainActor in self.statusLine = "Notification error: \(error.localizedDescription)" }
                return
            }
            guard granted else {
                Task { @MainActor in self.statusLine = "Notifications are not allowed in System Settings." }
                return
            }
            UNUserNotificationCenter.current().add(request) { error in
                Task { @MainActor in
                    self.statusLine = error.map { "Notification error: \($0.localizedDescription)" } ?? "Test notification scheduled."
                }
            }
        }
    }

    private func notifyAgentFinished(controllerID: String) {
        guard notificationsEnabled, let controller = controllers[controllerID] else { return }
        let content = UNMutableNotificationContent()
        content.title = "Agent finished"
        content.subtitle = controller.projectName
        content.body = controller.title.isEmpty || controller.title == "Untitled" ? "A background session completed." : "\(controller.title) completed."
        content.sound = .default
        var userInfo: [AnyHashable: Any] = ["controllerID": controllerID]
        if let sessionPath = controller.sessionPath { userInfo["sessionPath"] = sessionPath }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "PiG.agentFinished.\(controllerID).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func reportProjectTrustFailure(path: String, error: Error) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        statusLine = "Could not automatically trust project “\(name)”: \(error.localizedDescription). The project remains registered, but project-local resources were not loaded."
    }

    private func touchProject(_ path: String) {
        if let index = projects.firstIndex(where: { $0.path == path }) {
            projects[index].lastOpened = Date()
        } else {
            projects.append(ProjectInfo(path: path))
        }
        sortProjectsInPlace()
        saveRegistry()
    }

    private func sortProjectsInPlace() {
        projects = sortedProjects(projects, grouped: sessionsByProject)
    }

    private func pruneFileTreeExpanded() {
        var keep = Set(projects.map(\.path))
        if let selectedProjectPath { keep.insert(selectedProjectPath) }
        fileTreeExpandedByProject = fileTreeExpandedByProject.filter { keep.contains($0.key) }
    }

    private func sortedProjects(_ projects: [ProjectInfo], grouped: [String: [SessionSummary]]) -> [ProjectInfo] {
        projects.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.isPinned { return lhs.pinnedSortIndex < rhs.pinnedSortIndex }
            let lhsDate = max(lhs.lastOpened, grouped[lhs.path]?.first?.timestamp ?? Date.distantPast)
            let rhsDate = max(rhs.lastOpened, grouped[rhs.path]?.first?.timestamp ?? Date.distantPast)
            return lhsDate > rhsDate
        }
    }

    private func normalizePinnedSortIndexes() {
        let pinned = projects.filter(\.isPinned).sorted { $0.pinnedSortIndex < $1.pinnedSortIndex }
        for (order, project) in pinned.enumerated() {
            if let index = projects.firstIndex(where: { $0.path == project.path }) {
                projects[index].pinnedSortIndex = order
            }
        }
    }

    private func loadRegistry() async {
        projects = sortedProjects(await ProjectRegistryStore.load(), grouped: sessionsByProject)
    }

    private func loadPersistedInboxSummaries() async {
        let paths = sessionInboxIDs.compactMap(sessionPath(fromInboxID:))
        guard !paths.isEmpty else { return }
        let grouped = await SessionScanner.cachedSummaries(forPaths: paths)
        guard !grouped.isEmpty else { return }
        sessionsByProject = grouped
        projects = sortedProjects(projects, grouped: grouped)
    }

    private func loadCustomActions() async {
        customActionsByProject = await CustomActionStore.load()
    }

    func reloadModelCatalog() {
        Task { await loadSessionNamingModels() }
    }

    private func loadSessionNamingModels() async {
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

    private func saveRegistry() {
        let snapshot = projects
        ProjectRegistryStore.save(snapshot) { [weak self] error in
            self?.statusLine = "Could not save registry: \(error.localizedDescription)"
        }
    }
}
