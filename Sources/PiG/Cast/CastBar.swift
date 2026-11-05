import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Window top bar: inbox toggle, files, the current room (project or agent), new-chat
/// buttons, and window controls.
struct CastBar: View {
    static let height: CGFloat = 44

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 0) {
                Color.clear.frame(width: 78)
                InboxToggleButton()
                CastFilesButton()
                CastRoomButton()
                NewChatButtons()
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                CastTrailingControls()
                    .padding(.trailing, 12)
            }
        }
        .frame(height: Self.height)
    }
}

private struct NewChatButtons: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.startNewChat() } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help(model.sessionLaunchExtensions.isEmpty ? "New chat (⌘N)" : "New chat (⌘N) — right-click for more")
            .contextMenu { NewChatMenuItems() }

            Button { model.showNewChatHome(quickChat: true) } label: {
                Image(systemName: "bolt.fill")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help(model.sessionLaunchExtensions.isEmpty ? "New quick chat (⇧⌘N)" : "New quick chat (⇧⌘N) — right-click for more")
            .contextMenu { NewQuickChatMenuItems() }
        }
    }
}

struct NewChatMenuItems: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let path = model.selectedProject?.path {
            Button("New Chat in \(model.projectDisplayName(for: path))", systemImage: "square.and.pencil") {
                model.showNewChatHome(projectPath: path)
            }
            ForEach(model.sessionLaunchExtensions) { item in
                Button("New Chat with \(item.displayName)", systemImage: "puzzlepiece.extension") {
                    model.newSession(projectPath: path, extensionPaths: [item.path])
                }
            }
        }
        if !model.agents.isEmpty {
            Divider()
            ForEach(model.agents) { agent in
                Button("Chat with \(agent.name)") { model.selectAgent(agent.id) }
            }
        }
    }
}

struct NewQuickChatMenuItems: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button("New Quick Chat", systemImage: "bolt.fill") { model.showNewChatHome(quickChat: true) }
        ForEach(model.sessionLaunchExtensions) { item in
            Button("New Quick Chat with \(item.displayName)", systemImage: "puzzlepiece.extension") {
                model.newQuickChat(extensionPaths: [item.path])
            }
        }
    }
}

private struct InboxToggleButton: View {
    @AppStorage(InboxColumn.visibilityKey) private var visible = true

    var body: some View {
        Button { withAnimation(.smooth(duration: 0.22)) { visible.toggle() } } label: {
            Image(systemName: "sidebar.left")
        }
        .buttonStyle(TitlebarIconButtonStyle(active: visible))
        .help(visible ? "Collapse open chats (⌘S)" : "Expand open chats (⌘S)")
    }
}

// MARK: - Room

private struct CastRoomButton: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var open = false

    private var roomAgent: Agent? {
        if let agent = model.selectedAgent { return agent }
        if let controller = model.selectedController { return model.agent(for: controller) }
        return nil
    }

    private var isQuickChat: Bool {
        model.selectedController?.isQuickChat ?? (model.selectedControllerID == nil && model.composingQuickChat)
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) {
                if let agent = roomAgent {
                    AgentAvatar(look: agent.look, size: 16)
                    Text(agent.name)
                } else if isQuickChat {
                    Image(systemName: "bolt.fill")
                    Text("Quick chat")
                } else {
                    Text(model.selectedProject?.displayName ?? "Choose project")
                }
                Image(systemName: "chevron.down")
                    .font(AppFonts.ui(8.5, weight: .bold))
                    .foregroundStyle(appTheme.muted)
            }
            .font(AppFonts.ui(12.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(open ? appTheme.text : appTheme.secondaryText)
            .frame(maxWidth: 140, alignment: .leading)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch project")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ProjectPickerMenu(
                width: 620,
                showsQuickChat: true,
                showsPinButtons: true,
                isSelected: { model.selectedAgent == nil && model.selectedProjectPath == $0.path },
                selectProject: { model.selectProject($0) },
                quickChatSelected: isQuickChat,
                selectQuickChat: { model.showNewChatHome(quickChat: true) },
                dismiss: { open = false }
            )
            .glowPresentationBackground()
        }
    }
}

/// Project files in a popover, replacing the sidebar's Files tab.
private struct CastFilesButton: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var open = false

    private var projectPath: String? { model.activeProjectPath ?? model.selectedProjectPath }

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: open ? "folder.fill" : "folder")
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .disabled(projectPath == nil)
        .help("Files")
        .padding(.trailing, 4)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            Group {
                if let projectPath {
                    FileTreeView(
                        rootURL: URL(fileURLWithPath: projectPath, isDirectory: true),
                        expanded: model.expandedDirectories(forProjectPath: projectPath),
                        onExpandedChange: { model.setExpandedDirectories($0, forProjectPath: projectPath) }
                    )
                    .id(projectPath)
                }
            }
            .frame(width: 360, height: 540)
            .glowPresentationBackground()
            .environmentObject(model)
            .environment(\.appTheme, appTheme)
        }
    }
}

// MARK: - Trailing controls

private struct CastTrailingControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                NotificationCenter.default.post(name: .pigOpenPalette, object: nil)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help("Go to anything (⌘K)")
            Group {
                AppUpdateButton(updates: model.appUpdates)
                PiUpdateButton(maintenance: model.piMaintenance)
            }
            .buttonStyle(.plain)
            .font(AppFonts.ui(12.5, weight: .semibold))
            Button {
                model.showingPiResources = true
            } label: {
                Image(systemName: "puzzlepiece.extension")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help("Extensions & Resources")
            .popover(isPresented: $model.showingPiResources, arrowEdge: .bottom) {
                PiResourcesPopoverView()
                    .environmentObject(model)
                    .glowPresentationBackground()
            }
            TitlebarTerminalButton()
            SessionStatisticsToolbarButton()
            SessionTreeToolbarButton()
            CustomActionsToolbarButton()
        }
        .fixedSize()
    }
}

// MARK: - Model helpers

extension AppModel {
    func isInboxItemResolvable(_ itemID: String) -> Bool {
        inboxHermesChat(for: itemID) != nil || inboxController(for: itemID) != nil || inboxSummary(for: itemID) != nil
    }

    func isInboxItemSelected(_ itemID: String) -> Bool {
        if let chat = inboxHermesChat(for: itemID) { return selectedHermesChatID == chat.id }
        if let controller = inboxController(for: itemID) { return selectedControllerID == controller.id }
        if let summary = inboxSummary(for: itemID) { return selectedController?.sessionPath == summary.filePath }
        return false
    }

    func inboxItemTitle(_ itemID: String) -> String {
        if let chat = inboxHermesChat(for: itemID) { return chat.title }
        if let controller = inboxController(for: itemID) {
            return controller.title.isEmpty ? (controller.isQuickChat ? "Quick chat" : "Untitled") : controller.title
        }
        return inboxSummary(for: itemID)?.title ?? "Untitled"
    }

    func inboxItemSubtitle(_ itemID: String) -> String {
        if let chat = inboxHermesChat(for: itemID) { return hermesAgent(for: chat)?.name ?? "Hermes" }
        if let controller = inboxController(for: itemID) {
            return agent(for: controller)?.name ?? (controller.isQuickChat ? "Quick chat" : controller.projectName)
        }
        guard let summary = inboxSummary(for: itemID) else { return "" }
        if let agent = agent(forSessionPath: summary.filePath) { return agent.name }
        return isQuickChatInboxItem(itemID) ? "Quick chat" : projectDisplayName(for: summary.projectPath)
    }

    /// Status worth reading in a list: needs input, working, or a new reply.
    func inboxItemStatusText(_ itemID: String) -> String? {
        if let chat = inboxHermesChat(for: itemID) {
            let controller = hermesControllers[chat.id]
            if controller?.approval != nil { return "needs input" }
            if controller?.isWorking == true { return "working" }
            return hermesUnreadChatIDs.contains(chat.id) ? "new reply" : nil
        }
        if let controller = inboxController(for: itemID) {
            if controller.extensionUIPrompt != nil { return "needs input" }
            if controller.showsActivityIndicator { return "working" }
            return finishedUnseen(controller) ? "new reply" : nil
        }
        guard let summary = inboxSummary(for: itemID) else { return nil }
        if activeController(forSessionPath: summary.filePath) != nil { return "working" }
        return finishedUnseen(forSessionPath: summary.filePath) ? "new reply" : nil
    }

    func inboxItemIcon(_ itemID: String) -> ChatIcon {
        if let chat = inboxHermesChat(for: itemID) { return chatIcon(for: chat) }
        if let controller = inboxController(for: itemID) { return chatIcon(for: controller) }
        guard let summary = inboxSummary(for: itemID) else { return .quickChat }
        return chatIcon(for: summary)
    }

    func chatIcon(for controller: SessionController) -> ChatIcon {
        if let agent = agent(for: controller) { return .agent(agent.look) }
        return controller.isQuickChat ? .quickChat : .project(path: controller.projectPath)
    }

    func chatIcon(for summary: SessionSummary) -> ChatIcon {
        if let agent = agent(forSessionPath: summary.filePath) { return .agent(agent.look) }
        return isQuickChatsProject(summary.projectPath) ? .quickChat : .project(path: summary.projectPath)
    }

    func chatIcon(for chat: HermesChatRecord) -> ChatIcon {
        hermesAgent(for: chat).map { .agent($0.look) } ?? .project(color: "#9aa3ad")
    }

    /// Inbox ID of the selected chat, if it is open in the cast.
    var selectedInboxItemID: String? {
        sessionInboxIDs.first { isInboxItemSelected($0) }
    }

    func selectInboxItem(_ itemID: String) {
        if let chat = inboxHermesChat(for: itemID) {
            selectHermesChat(agentID: chat.agentID, chatID: chat.id)
        } else if let controller = inboxController(for: itemID) {
            selectController(controller)
        } else if let summary = inboxSummary(for: itemID) {
            selectSession(summary)
        }
    }

    /// New chat in the current agent or project, falling back to a quick chat.
    func startNewChat() {
        if let agent = selectedAgent {
            selectAgent(agent.id)
        } else if let path = selectedProject?.path {
            showNewChatHome(projectPath: path)
        } else {
            showNewChatHome(quickChat: true)
        }
    }

    /// True on the new-chat landing, when no open chat or agent is selected.
    var isComposingNewChat: Bool {
        selectedControllerID == nil && selectedHermesChatID == nil && selectedAgentID == nil
    }
}

// MARK: - Window dragging

/// Background for the top bar: drags the window, and double-click zooms it,
/// since the bar replaces the standard title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2 else {
                window?.performDrag(with: event)
                return
            }
            // Follow System Settings › Desktop & Dock › "Double-click a window's title bar to".
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window?.performMiniaturize(nil)
            case "None": break
            default: window?.performZoom(nil)
            }
        }
    }
}
