import SwiftUI
import AppKit

extension Notification.Name {
    /// Opens the command palette; the object is an optional `PaletteScope` raw value.
    static let pigOpenPalette = Notification.Name("pigOpenPalette")
}

/// What the palette searches. Typing a scope's prefix and a colon (`file:`) narrows to it.
enum PaletteScope: String, CaseIterable {
    case all, chats, sessions, agents, projects, files, models, actions

    var label: String {
        switch self {
        case .all: return "Everything"
        case .chats: return "Open chats"
        case .sessions: return "Sessions"
        case .agents: return "Agents"
        case .projects: return "Projects"
        case .files: return "Files"
        case .models: return "Models"
        case .actions: return "Actions"
        }
    }

    var prefix: String {
        switch self {
        case .all: return ""
        case .chats: return "chat"
        case .sessions: return "session"
        case .agents: return "agent"
        case .projects: return "project"
        case .files: return "file"
        case .models: return "model"
        case .actions: return "action"
        }
    }

    /// Short kind shown at the end of each row in mixed results.
    var kindLabel: String {
        switch self {
        case .all: return ""
        case .chats: return "open"
        case .sessions: return "session"
        case .agents: return "agent"
        case .projects: return "project"
        case .files: return "file"
        case .models: return "model"
        case .actions: return "action"
        }
    }

    static func matching(prefix text: String) -> PaletteScope? {
        let lower = text.lowercased()
        return allCases.first { $0 != .all && ($0.prefix == lower || $0.prefix + "s" == lower) }
    }
}

struct PaletteItem: Identifiable {
    enum Icon {
        case look(Look)
        case symbol(String)
        case file(URL)
    }

    let id: String
    let kind: PaletteScope
    let title: String
    var subtitle = ""
    let icon: Icon
    var checked = false
    var shortcut: String?
    var keywords = ""
    var fileURL: URL?
    let perform: () -> Void
}

struct CommandPalette: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var model: AppModel
    let initialScope: PaletteScope
    let dismiss: () -> Void

    @State private var query = ""
    @State private var scope: PaletteScope = .all
    @State private var selection = 0
    @State private var fileMatches: [FileNode] = []
    @State private var fileSearch: Task<Void, Never>?
    @FocusState private var fieldFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let results = results()
        ZStack(alignment: .top) {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            VStack(spacing: 0) {
                field(results: results)
                Rectangle().fill(appTheme.line.opacity(0.6)).frame(height: 1)
                list(results)
            }
            .frame(width: 600)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(appTheme.panel))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(appTheme.line.opacity(0.8), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 20)
            .padding(.top, 72)
        }
        .onAppear {
            scope = initialScope
            fieldFocused = true
            if model.sessionArchiveLoadState == .idle { model.loadSessionArchive() }
        }
        .onDisappear { fileSearch?.cancel() }
        .onChange(of: query) { _, text in
            if let colon = text.firstIndex(of: ":"), let match = PaletteScope.matching(prefix: String(text[..<colon])) {
                scope = match
                query = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                return
            }
            selection = 0
            searchFiles()
        }
        .onChange(of: scope) { _, _ in
            selection = 0
            searchFiles()
        }
    }

    private func field(results: [PaletteItem]) -> some View {
        HStack(spacing: 10) {
            if scope == .all {
                Image(systemName: "magnifyingglass")
                    .font(AppFonts.ui(15, weight: .medium))
                    .foregroundStyle(appTheme.muted)
            } else {
                Button { scope = .all } label: {
                    Text(scope.label)
                        .font(AppFonts.ui(15, weight: .semibold))
                        .foregroundStyle(appTheme.brass)
                }
                .buttonStyle(.plain)
                .help("Search everything")
            }
            TextField(scope == .all ? "Jump to anything" : "Search \(scope.label.lowercased())", text: $query)
                .textFieldStyle(.plain)
                .font(AppFonts.ui(17))
                .foregroundStyle(appTheme.text)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .textContentType(.none)
                .onSubmit { activate(results) }
                .onKeyPress(.downArrow) { move(1, in: results); return .handled }
                .onKeyPress(.upArrow) { move(-1, in: results); return .handled }
                .onKeyPress(.escape) { dismiss(); return .handled }
                .onKeyPress(.delete) {
                    guard query.isEmpty, scope != .all else { return .ignored }
                    scope = .all
                    return .handled
                }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }

    @ViewBuilder private func list(_ results: [PaletteItem]) -> some View {
        if results.isEmpty {
            Text(scope == .files && model.activeProjectPath == nil ? "Choose a project to search its files" : "Nothing matches")
                .font(AppFonts.ui(13))
                .foregroundStyle(appTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, selected: index == selection, showsKind: scope == .all)
                                .id(item.id)
                                .onHover { if $0 { selection = index } }
                                .onTapGesture { run(item) }
                                .contextMenu { fileMenu(item) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: selection) { _, index in
                    guard results.indices.contains(index) else { return }
                    proxy.scrollTo(results[index].id)
                }
            }
        }
    }

    @ViewBuilder private func fileMenu(_ item: PaletteItem) -> some View {
        if let url = item.fileURL {
            Button("Open") { NSWorkspace.shared.open(url); dismiss() }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]); dismiss() }
            Button("Open in Terminal") {
                let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                let directory = isDirectory ? url : url.deletingLastPathComponent()
                NotificationCenter.default.post(name: .pigOpenTerminalAtPath, object: directory.path)
                dismiss()
            }
            Divider()
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }

    // MARK: Keyboard

    private func move(_ delta: Int, in results: [PaletteItem]) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func activate(_ results: [PaletteItem]) {
        guard results.indices.contains(selection) else { return }
        run(results[selection])
    }

    private func run(_ item: PaletteItem) {
        dismiss()
        item.perform()
    }

    // MARK: Results

    private func results() -> [PaletteItem] {
        let text = trimmedQuery
        let tokens = text.lowercased().split(separator: " ").map(String.init)
        let sources: [PaletteScope] = scope == .all
            ? (text.isEmpty ? [.chats, .agents, .projects, .sessions] : [.chats, .agents, .projects, .actions, .models, .sessions, .files])
            : [scope]
        var items: [PaletteItem] = []
        for source in sources {
            var batch = self.items(for: source)
            if scope == .all, text.isEmpty, source == .sessions { batch = Array(batch.prefix(8)) }
            items += batch
        }
        guard !tokens.isEmpty else { return Array(items.prefix(120)) }
        let ranked = items.enumerated().compactMap { index, item -> (Int, Int, PaletteItem)? in
            let title = item.title.lowercased()
            let haystack = "\(title) \(item.subtitle.lowercased()) \(item.keywords)"
            guard tokens.allSatisfy(haystack.contains) else { return nil }
            let score = title.hasPrefix(text.lowercased()) ? 0 : title.contains(tokens[0]) ? 1 : 2
            return (score, index, item)
        }
        return ranked.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(120).map(\.2)
    }

    private func items(for source: PaletteScope) -> [PaletteItem] {
        switch source {
        case .all: return []
        case .chats: return chatItems()
        case .sessions: return sessionItems()
        case .agents: return agentItems()
        case .projects: return projectItems()
        case .files: return fileItems()
        case .models: return modelItems()
        case .actions: return actionItems()
        }
    }

    private func chatItems() -> [PaletteItem] {
        model.sessionInboxIDs.filter(model.isInboxItemResolvable).map { id in
            PaletteItem(
                id: "chat:\(id)", kind: .chats,
                title: model.inboxItemTitle(id),
                subtitle: model.inboxItemSubtitle(id),
                icon: .look(model.inboxItemLook(id)),
                checked: model.isInboxItemSelected(id)
            ) { model.selectInboxItem(id) }
        }
    }

    private func sessionItems() -> [PaletteItem] {
        let open = Set(model.sessionInboxIDs)
        var seen = Set<String>()
        let all = (model.sessionsByProject.values.flatMap { $0 } + model.archivedSessionsByProject.values.flatMap { $0 })
            .filter { seen.insert($0.filePath).inserted }
            .sorted { $0.timestamp > $1.timestamp }
        let sessions = all.compactMap { summary -> PaletteItem? in
            guard scope == .sessions || !open.contains(model.inboxID(forSessionPath: summary.filePath)) else { return nil }
            let place = model.agent(forSessionPath: summary.filePath)?.name ?? model.projectDisplayName(for: summary.projectPath)
            return PaletteItem(
                id: "session:\(summary.filePath)", kind: .sessions,
                title: summary.title.isEmpty ? "Untitled" : summary.title,
                subtitle: "\(place), \(summary.timestamp.formatted(.relative(presentation: .named)))",
                icon: .look(model.sessionLook(summary))
            ) { model.selectSession(summary) }
        }
        let hermes = model.hermesChats
            .filter { !open.contains("hermes:\($0.id)") || scope == .sessions }
            .map { chat in
                PaletteItem(
                    id: "hermes:\(chat.id)", kind: .sessions,
                    title: chat.title,
                    subtitle: model.hermesAgent(for: chat)?.name ?? "Hermes",
                    icon: .look(model.hermesAgent(for: chat)?.look ?? Look.seeded(key: chat.id, projectPath: nil))
                ) { model.selectHermesChat(agentID: chat.agentID, chatID: chat.id) }
            }
        return sessions + hermes
    }

    private func agentItems() -> [PaletteItem] {
        model.agents.map { agent in
            PaletteItem(
                id: "agent:\(agent.id)", kind: .agents,
                title: agent.name, subtitle: agent.role,
                icon: .look(agent.look),
                checked: model.selectedAgentID == agent.id
            ) { model.selectAgent(agent.id) }
        }
    }

    private func projectItems() -> [PaletteItem] {
        let projects = model.projects.filter { !model.isQuickChatsProject($0.path) }.map { project in
            PaletteItem(
                id: "project:\(project.path)", kind: .projects,
                title: project.displayName,
                subtitle: project.path.abbreviatingHomeDirectory(),
                icon: .symbol(project.isPinned ? "pin" : "folder"),
                checked: model.selectedAgent == nil && model.selectedProjectPath == project.path
            ) { model.showNewChatHome(projectPath: project.path) }
        }
        return projects + [
            PaletteItem(id: "project:add", kind: .projects, title: "Add Existing Project…", icon: .symbol("folder.badge.plus")) {
                model.addExistingProject()
            },
            PaletteItem(id: "project:create", kind: .projects, title: "Create Project Directory…", icon: .symbol("plus.square")) {
                model.createProject()
            },
        ]
    }

    private func fileItems() -> [PaletteItem] {
        guard let root = model.activeProjectPath else { return [] }
        return fileMatches.map { node in
            let relative = node.url.path.hasPrefix(root + "/") ? String(node.url.path.dropFirst(root.count + 1)) : node.url.path
            let parent = (relative as NSString).deletingLastPathComponent
            return PaletteItem(
                id: "file:\(node.url.path)", kind: .files,
                title: node.url.lastPathComponent,
                subtitle: parent,
                icon: .file(node.url),
                fileURL: node.url
            ) { mentionOrOpen(node, relativePath: relative) }
        }
    }

    private func modelItems() -> [PaletteItem] {
        guard let controller = model.activeComposerController else { return [] }
        let quick = (1...5).map { UserDefaults.standard.string(forKey: QuickModelSlots.key($0)) ?? "" }
        let models = controller.models.map { info in
            PaletteItem(
                id: "model:\(info.id)", kind: .models,
                title: info.name.isEmpty ? info.modelId : info.name,
                subtitle: info.provider,
                icon: .symbol("cpu"),
                checked: controller.selectedModelID == info.id,
                shortcut: quick.firstIndex(of: info.id).map { "⌘\($0 + 1)" }
            ) { controller.setModel(info.id) }
        }
        let levels = controller.availableThinkingLevels.map { level in
            PaletteItem(
                id: "thinking:\(level)", kind: .models,
                title: "Thinking: \(level)",
                icon: .symbol("brain"),
                checked: controller.thinkingLevel == level,
                keywords: "reasoning effort"
            ) { controller.setThinkingLevel(level) }
        }
        return models + levels
    }

    private func actionItems() -> [PaletteItem] {
        var items: [PaletteItem] = []
        func add(_ id: String, _ title: String, _ symbol: String, shortcut: String? = nil, keywords: String = "", _ perform: @escaping () -> Void) {
            items.append(PaletteItem(id: "action:\(id)", kind: .actions, title: title, icon: .symbol(symbol), shortcut: shortcut, keywords: keywords, perform: perform))
        }
        for action in model.selectedCustomActions {
            add("custom:\(action.id)", action.title, action.symbolName, keywords: action.command) { model.runCustomAction(action) }
        }
        add("new-chat", "New Chat", "square.and.pencil", shortcut: "⌘N") {
            if let agent = model.selectedAgent { model.selectAgent(agent.id) } else { model.showNewChatHome() }
        }
        add("new-quick-chat", "New Quick Chat", "bolt.fill", shortcut: "⇧⌘N") { model.showNewChatHome(quickChat: true) }
        if let controller = model.selectedController {
            if controller.sessionPath != nil, !controller.showsActivityIndicator {
                add("rename", "Rename Chat…", "pencil") { model.requestSessionRename(controller) }
            }
            add("tree", "Session Tree", "point.3.connected.trianglepath.dotted", keywords: "fork branch history") {
                model.showingSessionTree = true
            }
        }
        if let itemID = model.selectedInboxItemID {
            add("done", "Mark Chat Done", "checkmark", keywords: "close dismiss") { model.markInboxItemDone(itemID) }
        }
        if let title = model.inboxDismissalUndoTitle {
            add("undo-done", "Reopen “\(title)”", "arrow.uturn.backward", keywords: "undo done") { model.undoLastInboxDismissal() }
        }
        add("terminal", "Toggle Terminal", "terminal") { post(.pigToggleTerminal) }
        add("terminal-full", "Fullscreen Terminal", "rectangle.inset.filled", shortcut: "⇧⌘F") { post(.pigToggleFullscreenTerminal) }
        add("terminal-vertical", "Vertical Terminal Split", "rectangle.split.2x1", shortcut: "⌘D") { post(.pigShowVerticalTerminalSplit) }
        add("terminal-horizontal", "Horizontal Terminal Split", "rectangle.split.1x2", shortcut: "⇧⌘D") { post(.pigShowHorizontalTerminalSplit) }
        add("terminal-tab", "New Terminal Tab", "plus.rectangle") { post(.pigNewTerminalTab) }
        add("resources", "Extensions & Resources", "puzzlepiece.extension", keywords: "skills") { model.showingPiResources = true }
        add("thinking-traces", model.showThinkingTraces ? "Hide Thinking Traces" : "Show Thinking Traces", "text.bubble") {
            model.showThinkingTraces.toggle()
        }
        add("reload-idle", "Reload All Idle Session Runtimes", "arrow.clockwise") { model.reloadAllIdleSessionRuntimes() }
        add("unload-idle", "Unload All Idle Sessions", "moon.zzz") { model.unloadAllIdleSessions() }
        add("pi-updates", "Pi Updates…", "arrow.down.circle") {
            model.piMaintenance.presentUpdates(
                cwd: model.selectedController?.projectPath ?? model.selectedProjectPath ?? PiPaths.home.path,
                projectName: model.selectedProject?.displayName
            )
        }
        for theme in AppThemeChoice.allCases where theme != model.selectedTheme {
            add("theme:\(theme.rawValue)", "Theme: \(theme.displayName)", "paintpalette", keywords: "appearance color") {
                model.selectedTheme = theme
            }
        }
        add("settings", "Settings…", "gearshape", shortcut: "⌘,") { openSettings() }
        return items
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }

    // MARK: Files

    private func searchFiles() {
        fileSearch?.cancel()
        let text = trimmedQuery
        guard scope == .files || (scope == .all && text.count >= 3), !text.isEmpty, let root = model.activeProjectPath else {
            fileMatches = []
            return
        }
        fileSearch = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                FileTreeLoader.search(root: URL(fileURLWithPath: root), query: text, showHidden: false)
            }.value
            guard !Task.isCancelled else { return }
            fileMatches = Array(matches.prefix(scope == .files ? 200 : 20))
        }
    }

    /// Mentions the file in the chat composer when it belongs to the composer's project,
    /// otherwise opens it.
    private func mentionOrOpen(_ node: FileNode, relativePath: String) {
        guard let controller = model.activeComposerController,
              node.url.path.hasPrefix(controller.projectPath + "/") else {
            NSWorkspace.shared.open(node.url)
            return
        }
        let suggestion = ComposerFileSuggestion(
            relativePath: relativePath,
            isDirectory: node.isDirectory,
            replacementRange: NSRange(location: 0, length: 0),
            replacementText: ""
        )
        controller.composerPrefillRequest = ComposerPrefillRequest(
            text: ComposerCompletion.replacingFileSuggestion(suggestion, in: ""),
            insertsAtEnd: true
        )
    }
}

private struct PaletteRow: View {
    @Environment(\.appTheme) private var appTheme
    let item: PaletteItem
    let selected: Bool
    let showsKind: Bool

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(AppFonts.ui(13.5, weight: .medium))
                    .foregroundStyle(appTheme.text)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if item.checked {
                Image(systemName: "checkmark")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
            }
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(appTheme.muted)
            }
            if showsKind {
                Text(item.kind.kindLabel)
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(appTheme.muted.opacity(0.8))
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? appTheme.panel2 : .clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var icon: some View {
        switch item.icon {
        case .look(let look):
            AgentAvatar(look: look, size: 26)
        case .symbol(let name):
            Image(systemName: name)
                .font(AppFonts.ui(12, weight: .medium))
                .foregroundStyle(appTheme.secondaryText)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(appTheme.panel2))
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 22, height: 22)
        }
    }
}

extension AppModel {
    /// Project whose files the palette searches: the selected chat's project, else the selected project.
    var activeProjectPath: String? {
        if let controller = activeComposerController, !controller.isQuickChat { return controller.projectPath }
        guard let path = selectedProjectPath, !isQuickChatsProject(path) else { return nil }
        return path
    }
}
