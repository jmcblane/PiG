import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Window top bar: new chat beside the traffic lights, then files and window controls.
struct CastBar: View {
    static let height: CGFloat = 44
    static let controlsHeight: CGFloat = 32

    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            WindowDragArea()
            HStack(spacing: 0) {
                Color.clear.frame(width: 78)
                Button { model.startNewChat() } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(TitlebarIconButtonStyle(active: model.isOnNewChatHome))
                .help("New chat (⌘N)")
                .accessibilityLabel("New chat")
                Spacer(minLength: 0)
                CastTrailingControls()
                    .padding(.trailing, 12)
            }
            .frame(height: Self.controlsHeight)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(height: Self.height)
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
        .accessibilityLabel("Files")
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
            Group {
                AppUpdateButton(updates: model.appUpdates)
                PiUpdateButton(maintenance: model.piMaintenance)
            }
            .buttonStyle(.plain)
            .font(AppFonts.ui(12.5, weight: .semibold))
            CastFilesButton()
                .padding(.leading, 10)
            TitlebarTerminalButton()
            CustomActionsToolbarButton()
        }
        .fixedSize()
        .background(alignment: .trailing) { SessionTreePopoverAnchor() }
    }
}

// MARK: - Model helpers

extension AppModel {
    func isInboxItemResolvable(_ itemID: String) -> Bool {
        inboxACPChat(for: itemID) != nil
            || inboxHermesChat(for: itemID) != nil
            || inboxController(for: itemID) != nil
            || inboxSummary(for: itemID) != nil
    }

    func isInboxItemSelected(_ itemID: String) -> Bool {
        if let chat = inboxACPChat(for: itemID) { return selectedACPChatID == chat.id }
        if let chat = inboxHermesChat(for: itemID) { return selectedHermesChatID == chat.id }
        if let controller = inboxController(for: itemID) { return selectedControllerID == controller.id }
        if let summary = inboxSummary(for: itemID) { return selectedController?.sessionPath == summary.filePath }
        return false
    }

    func inboxItemTitle(_ itemID: String) -> String {
        if let chat = inboxACPChat(for: itemID) {
            if let controller = acpControllers[chat.id], !controller.title.isEmpty { return controller.title }
            return chat.title.isEmpty ? (chat.isQuickChat ? "Quick chat" : "Untitled") : chat.title
        }
        if let chat = inboxHermesChat(for: itemID) { return chat.title }
        if let controller = inboxController(for: itemID) {
            return controller.title.isEmpty ? (controller.isQuickChat ? "Quick chat" : "Untitled") : controller.title
        }
        return inboxSummary(for: itemID)?.title ?? "Untitled"
    }

    func inboxItemSubtitle(_ itemID: String) -> String {
        if let chat = inboxACPChat(for: itemID) {
            let place = chat.isQuickChat ? "Quick chat" : projectDisplayName(for: chat.projectPath)
            return "\(place) · \(ACPProvider.antigravityDisplayName)"
        }
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
        if let chat = inboxACPChat(for: itemID) {
            let controller = acpControllers[chat.id]
            if controller?.permissionPrompt != nil { return "needs input" }
            if controller?.isWorking == true { return "working" }
            return acpUnreadChatIDs.contains(chat.id) ? "new reply" : nil
        }
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
        if let chat = inboxACPChat(for: itemID) { return chatIcon(for: chat) }
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

    func chatIcon(for chat: ACPChatRecord) -> ChatIcon {
        chat.isQuickChat ? .quickChat : .project(path: chat.projectPath)
    }

    /// Inbox ID of the selected chat, if it is open in the cast.
    var selectedInboxItemID: String? {
        sessionInboxIDs.first { isInboxItemSelected($0) }
    }

    func selectInboxItem(_ itemID: String) {
        if let chat = inboxACPChat(for: itemID) {
            selectACPChat(chat.id)
        } else if let chat = inboxHermesChat(for: itemID) {
            selectHermesChat(agentID: chat.agentID, chatID: chat.id)
        } else if let controller = inboxController(for: itemID) {
            selectController(controller)
        } else if let summary = inboxSummary(for: itemID) {
            selectSession(summary)
        }
    }

    /// New chat in the current agent or project, falling back to a quick chat
    /// when not in a project (e.g. quick chat or empty state).
    func startNewChat() {
        if let chatID = selectedHermesChatID,
           let chat = inboxHermesChat(for: "hermes:\(chatID)"),
           let agent = hermesAgent(for: chat) {
            selectAgent(agent.id)
            return
        }
        if let agent = selectedAgent {
            selectAgent(agent.id)
            return
        }
        if let acp = selectedACPController {
            if acp.isQuickChat {
                showNewChatHome(quickChat: true)
            } else {
                showNewChatHome(projectPath: acp.projectPath)
            }
            return
        }
        if let acpRecord = selectedACPChatRecord {
            if acpRecord.isQuickChat {
                showNewChatHome(quickChat: true)
            } else {
                showNewChatHome(projectPath: acpRecord.projectPath)
            }
            return
        }
        if let controller = selectedController {
            if controller.isQuickChat {
                showNewChatHome(quickChat: true)
            } else {
                showNewChatHome(projectPath: controller.projectPath)
            }
            return
        }
        if !composingQuickChat,
           let path = selectedProjectPath,
           !isQuickChatsProject(path) {
            showNewChatHome(projectPath: path)
        } else {
            showNewChatHome(quickChat: true)
        }
    }

    /// True on the unified new-chat home (no open chat selected).
    var isOnNewChatHome: Bool {
        selectedControllerID == nil
            && selectedHermesChatID == nil
            && selectedACPChatID == nil
    }

    /// True on the new-chat landing, when no open chat or agent is selected.
    var isComposingNewChat: Bool {
        isOnNewChatHome && selectedAgentID == nil
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
