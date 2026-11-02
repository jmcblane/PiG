import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var renameText = ""
    @State private var paletteScope: PaletteScope?
    @AppStorage(InboxColumn.visibilityKey) private var inboxVisible = true

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.sanitizedForLayout

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    CastBar()
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 0) {
                            if inboxVisible {
                                InboxColumn()
                                    .transition(.move(edge: .leading))
                            }
                            ChatPaneView(controller: model.selectedController)
                                .padding(.leading, inboxVisible ? 0 : InboxColumn.railWidth)
                        }
                        if !inboxVisible {
                            InboxRail(windowSize: size)
                                .transition(.opacity)
                        }
                    }
                    .clipped()
                }
                .frame(width: size.width, height: size.height)

                VStack(alignment: .trailing, spacing: 8) {
                    PiMaintenanceHost(controller: model.piMaintenance, theme: model.selectedTheme)
                    UnifiedGlobalToast()
                }
                .padding(.top, CastBar.height + 8)
                .padding(.trailing, 16)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
                .zIndex(10)

                if let scope = paletteScope {
                    CommandPalette(initialScope: scope) { paletteScope = nil }
                        .frame(width: size.width, height: size.height)
                        .zIndex(15)
                }

                if let promptController = model.extensionPromptController,
                   let prompt = promptController.extensionUIPrompt {
                    Color.black.opacity(0.36)
                        .contentShape(Rectangle())
                        .frame(width: size.width, height: size.height)
                        .zIndex(19)
                    ExtensionUIPromptView(controller: promptController, prompt: prompt)
                        .id("\(promptController.id):\(prompt.id)")
                        .padding(.horizontal, 24)
                        .padding(.bottom, 90)
                        .frame(width: size.width, height: size.height, alignment: .bottom)
                        .zIndex(20)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .onChange(of: model.sessionPendingRename?.id) { _, _ in
                renameText = model.sessionPendingRename?.title ?? ""
            }
            .alert("Rename Session", isPresented: Binding(
                get: { model.sessionPendingRename != nil },
                set: { if !$0 { model.sessionPendingRename = nil } }
            )) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { model.sessionPendingRename = nil }
                Button("Rename") {
                    if let request = model.sessionPendingRename {
                        model.renameSession(request, to: renameText)
                    }
                    model.sessionPendingRename = nil
                }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background { WindowBackdrop() }
        .onReceive(NotificationCenter.default.publisher(for: .pigOpenPalette)) { notification in
            let scope = (notification.object as? String).flatMap(PaletteScope.init(rawValue:)) ?? .all
            paletteScope = paletteScope == scope ? nil : scope
        }
        .background(appTheme.background)
        .font(AppFonts.ui(14))
        .sheet(item: Binding(
            get: { model.agentEditorInSettings ? nil : model.agentEditorRequest },
            set: { model.agentEditorRequest = $0 }
        )) { request in
            AgentEditorView(request: request)
                .environmentObject(model)
                .environment(\.appTheme, appTheme)
        }
        .alert(item: $model.sessionPendingDeletion) { request in
            Alert(
                title: Text("Move Session to Trash?"),
                message: Text("“\(request.title.isEmpty ? "Untitled" : request.title)” will be removed from PiG and moved to the Trash."),
                primaryButton: .destructive(Text("Move to Trash")) {
                    model.deleteSession(request)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

/// Theme background, plus the theme's glow (warm from the top, cool from the corner) if it has one.
struct WindowBackdrop: View {
    @Environment(\.appTheme) private var appTheme

    var body: some View {
        ZStack {
            appTheme.background
            if let glow = appTheme.choice.glow {
                GeometryReader { geometry in
                    let size = geometry.size
                    RadialGradient(
                        colors: [glow.top.color.opacity(0.13), .clear],
                        center: UnitPoint(x: 0.5, y: -0.1),
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.6
                    )
                    RadialGradient(
                        colors: [glow.corner.color.opacity(0.06), .clear],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: max(size.width, size.height) * 0.55
                    )
                }
            }
        }
        .ignoresSafeArea()
    }
}

private extension CGSize {
    var sanitizedForLayout: CGSize {
        CGSize(width: max(1, width.isFinite ? width : 1), height: max(1, height.isFinite ? height : 1))
    }
}

/// Single arbitrated toast for the whole window: at most one of chat error,
/// extension notification, or status line is visible at a time (in that
/// priority order). A dismissed chat error falls through to the other sources.
/// Dismissing never clears the underlying errorText; full text stays available
/// via the 'Last error' affordance near the composer.
private struct UnifiedGlobalToast: View {
    @EnvironmentObject private var model: AppModel
    @State private var dismissedStatus: String?

    var body: some View {
        Group {
            if let controller = model.selectedController {
                ChatAwareToastBranch(controller: controller, dismissedStatus: $dismissedStatus)
                    .id(controller.id)
            } else {
                ExtensionOrStatusToast(dismissedStatus: $dismissedStatus)
            }
        }
    }
}

/// Observes the selected controller so chat-error changes re-render; status
/// dismissal lives in the parent so switching sessions does not re-arm it.
private struct ChatAwareToastBranch: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    @Binding var dismissedStatus: String?

    private var visibleChatError: String? {
        guard let error = controller.errorText, !error.isEmpty else { return nil }
        if controller.dismissedErrorToast == error {
            return nil
        }
        return error
    }

    var body: some View {
        Group {
            if let error = visibleChatError {
                AutoDismissToast(
                    id: "chat-error-\(controller.id)-\(error)",
                    accent: appTheme.danger,
                    duration: 5,
                    dismiss: { controller.dismissedErrorToast = error }
                ) {
                    Text(error)
                        .font(AppFonts.ui(13))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(error)
                        .contextMenu {
                            Button("Copy Error") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(error, forType: .string)
                            }
                        }
                }
            } else {
                ExtensionOrStatusToast(dismissedStatus: $dismissedStatus)
            }
        }
    }
}

/// Extension notification first, status line only when no extension is pending.
private struct ExtensionOrStatusToast: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @Binding var dismissedStatus: String?

    var body: some View {
        Group {
            if !model.extensionNotificationPresentations.isEmpty {
                ExtensionNotificationsView(items: model.extensionNotificationPresentations)
            } else {
                let text = model.statusLine
                if !text.isEmpty, text != dismissedStatus {
                    AutoDismissToast(
                        id: "status-\(text)",
                        accent: appTheme.brass,
                        duration: 4,
                        dismiss: {
                            dismissedStatus = text
                            if model.statusLine == text { model.statusLine = "" }
                        }
                    ) {
                        Text(text)
                            .font(AppFonts.ui(13))
                            .foregroundStyle(appTheme.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(text)
                    }
                }
            }
        }
    }
}

/// Shown when a newer PiG release exists on GitHub; opens its release page.
struct AppUpdateButton: View {
    @ObservedObject var updates: AppUpdateChecker

    var body: some View {
        if let release = updates.notice {
            Button { updates.download() } label: {
                Image(systemName: "arrow.down.app.fill")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.blue)
            .help("PiG \(release.version) is available — click to download")
            .accessibilityLabel("Download PiG \(release.version)")
            .contextMenu {
                Button("Download PiG \(release.version)") { updates.download() }
                Divider()
                Button("Dismiss Notice") { updates.dismiss() }
            }
        }
    }
}

/// Small colorful affordance for Pi / extension updates in the top bar. Opens the existing update review sheet; changelog and
/// update actions live there. When only the installed notice remains (nothing
/// to download), it shows an info icon that opens the changelog instead.
struct PiUpdateButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var maintenance: PiMaintenanceController

    private var hasPiRelease: Bool { maintenance.availableRelease != nil }
    private var hasPackageUpdates: Bool { !maintenance.visiblePackageUpdates.isEmpty }
    private var hasInstalledNotice: Bool { maintenance.installedUpdateNoticeVersion != nil }
    private var hasActionableUpdates: Bool { hasPiRelease || hasPackageUpdates }

    var body: some View {
        if hasActionableUpdates {
            Button(action: openReview) {
                Image(systemName: "arrow.down.circle.fill")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(hasPiRelease ? Color.orange : Color.green)
            .help(helpText)
            .accessibilityLabel("Review available updates")
            .contextMenu {
                Button("Review Updates") { openReview() }
                if hasInstalledNotice {
                    Button("What’s New") { maintenance.openChangelog(showAll: false) }
                }
                Divider()
                Button("Dismiss Notices") { dismissAll() }
            }
        } else if let version = maintenance.installedUpdateNoticeVersion {
            Button { maintenance.openChangelog(showAll: false) } label: {
                Image(systemName: "info.circle.fill")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(Color.green)
            .help("Updated to Pi \(version) — click to see what’s new")
            .accessibilityLabel("See what’s new in Pi \(version)")
            .contextMenu {
                Button("What’s New") { maintenance.openChangelog(showAll: false) }
                Divider()
                Button("Dismiss Notice") { maintenance.dismissInstalledUpdateNotice() }
            }
        }
    }

    private var helpText: String {
        var parts: [String] = []
        if let release = maintenance.availableRelease {
            parts.append("Pi \(release.version) is available")
        }
        if hasPackageUpdates {
            parts.append("\(maintenance.visiblePackageUpdates.count) extension update\(maintenance.visiblePackageUpdates.count == 1 ? "" : "s")")
        }
        if let version = maintenance.installedUpdateNoticeVersion {
            parts.append("Updated to Pi \(version)")
        }
        return (parts.isEmpty ? ["Updates"] : parts).joined(separator: "; ") + " — click to review"
    }

    private func openReview() {
        let cwd = model.selectedController?.projectPath
            ?? model.selectedProjectPath
            ?? maintenance.contextPath
        let projectName = model.projects.first(where: { $0.path == cwd })?.displayName
        maintenance.presentUpdates(cwd: cwd, projectName: projectName)
    }

    private func dismissAll() {
        if hasPiRelease { maintenance.dismissReleaseNotice() }
        if hasPackageUpdates { maintenance.dismissPackageNotice() }
        if hasInstalledNotice { maintenance.dismissInstalledUpdateNotice() }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var model: AppModel
    let summary: SessionSummary
    var showsProject = false
    var archived = false
    var childDisclosureExpanded: Bool? = nil
    var childDisclosureAction: (() -> Void)? = nil

    private var subtitle: String {
        let base = "\(summary.timestamp.sidebarLabel)   \(summary.messageCount) msgs"
        let owner = model.agent(forSessionPath: summary.filePath)
        return showsProject || owner != nil ? "\(owner?.name ?? model.projectDisplayName(for: summary.projectPath))   ·   \(base)" : base
    }

    var body: some View {
        SessionListRow(
            title: summary.title,
            subtitle: subtitle,
            agentLook: model.agent(forSessionPath: summary.filePath)?.look,
            selected: model.selectedController?.sessionPath == summary.filePath,
            named: summary.named,
            active: model.activeController(forSessionPath: summary.filePath) != nil,
            loaded: model.loadedController(forSessionPath: summary.filePath) != nil,
            finishedUnseen: model.finishedUnseen(forSessionPath: summary.filePath),
            indent: archived ? 22 : (summary.isChildSession ? 42 : 22),
            childDisclosureExpanded: childDisclosureExpanded,
            childDisclosureAction: childDisclosureAction
        ) { model.selectSession(summary) }
        .contextMenu { SessionSummaryContextMenu(summary: summary) }
    }
}

struct QuickChatContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController

    var body: some View {
        if controller.sessionPath != nil {
            Button("Rename…", systemImage: "pencil") { model.requestSessionRename(controller) }
                .disabled(controller.showsActivityIndicator)
        }
        Button("Close Quick Chat") { model.closeQuickChat(controller) }
            .disabled(controller.showsActivityIndicator)
        Divider()
        Button("Close Other Quick Chats") { model.closeOtherQuickChats(keeping: controller) }
        Button("Close All Quick Chats") { model.closeAllQuickChats() }
    }
}

struct ControllerSessionContextMenu: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController

    var body: some View {
        Button("Rename…", systemImage: "pencil") { model.requestSessionRename(controller) }
            .disabled(controller.sessionPath == nil || controller.showsActivityIndicator)
            .help(controller.sessionPath == nil ? "Save this session before renaming it." : "Rename session")
        Button("Reconnect") { model.reconnect(controller) }
            .disabled(controller.isProcessActive)
        Button("Reload Session Runtime") { model.reloadSessionRuntime(controller) }
            .disabled(!model.canReloadSessionRuntime(controller))
        Button("Unload Session") { model.unload(controller) }
            .disabled(!controller.isProcessActive || controller.showsActivityIndicator)
        Divider()
        Button("Reload All Idle Session Runtimes") { model.reloadAllIdleSessionRuntimes() }
            .disabled(!model.canReloadAnyIdleSessionRuntime)
        Button("Unload Other Idle Sessions") { model.unloadOtherSessions(keeping: controller) }
        Button("Unload All Idle Sessions") { model.unloadAllIdleSessions() }
        if controller.sessionPath != nil {
            Divider()
            Button("Move to Trash…", role: .destructive) { model.requestSessionDeletion(controller) }
                .disabled(controller.showsActivityIndicator)
        }
    }
}

struct SessionSummaryContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let summary: SessionSummary

    var body: some View {
        let loadedController = model.loadedController(forSessionPath: summary.filePath)
        Button("Open") { model.selectSession(summary) }
        Button("Rename…", systemImage: "pencil") { model.requestSessionRename(summary) }
            .disabled(model.activeController(forSessionPath: summary.filePath) != nil)
        Button("Reconnect") { model.reconnectSession(summary) }
        Button("Reload Session Runtime") { model.reloadSessionRuntime(path: summary.filePath) }
            .disabled(!model.canReloadSessionRuntime(loadedController))
        Button("Unload Session") { model.unloadSession(path: summary.filePath) }
        Divider()
        Button("Reload All Idle Session Runtimes") { model.reloadAllIdleSessionRuntimes() }
            .disabled(!model.canReloadAnyIdleSessionRuntime)
        Button("Unload Other Idle Sessions") { model.unloadOtherSessions(keeping: model.selectedController) }
        Button("Unload All Idle Sessions") { model.unloadAllIdleSessions() }
        Divider()
        Button("Move to Trash…", role: .destructive) { model.requestSessionDeletion(summary) }
            .disabled(model.activeController(forSessionPath: summary.filePath) != nil)
    }
}

struct SessionListRow: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let subtitle: String
    var agentLook: Look? = nil
    let selected: Bool
    let named: Bool
    let active: Bool
    let loaded: Bool
    let finishedUnseen: Bool
    let indent: CGFloat
    var childDisclosureExpanded: Bool? = nil
    var childDisclosureAction: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 8) {
                    SessionStatusIndicator(active: active, selected: selected, loaded: loaded, finishedUnseen: finishedUnseen)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(AppFonts.ui(13.5, weight: named ? .semibold : .regular))
                            .foregroundStyle(selected ? appTheme.text : appTheme.secondaryText)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            if let agentLook { AgentAvatar(look: agentLook, size: 16) }
                            Text(subtitle)
                                .font(AppFonts.ui(11.5))
                                .foregroundStyle(appTheme.muted)
                        }
                    }
                    Spacer()
                }
                .padding(.leading, indent)
                .padding(.trailing, childDisclosureAction == nil ? 10 : 34)
                .padding(.vertical, 7)
                .background(selected ? appTheme.brass.opacity(0.08) : (hovering ? appTheme.panel2.opacity(0.4) : Color.clear))
                .overlay(alignment: .leading) {
                    if selected {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(appTheme.brass)
                            .frame(width: 2)
                            .padding(.vertical, 6)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let childDisclosureExpanded, let childDisclosureAction {
                Button(action: childDisclosureAction) {
                    Image(systemName: "chevron.right")
                        .font(AppFonts.ui(13, weight: .semibold))
                        .foregroundStyle(appTheme.secondaryText)
                        .rotationEffect(.degrees(childDisclosureExpanded ? 90 : 0))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .animation(.easeInOut(duration: 0.16), value: childDisclosureExpanded)
                .padding(.trailing, 8)
                .help(childDisclosureExpanded ? "Hide child sessions" : "Show child sessions")
            }
        }
        .onHover { hovering = $0 }
    }
}

extension String {
    func abbreviatingHomeDirectory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + String(dropFirst(home.count)) }
        return self
    }
}

struct EmptyState: View {
    @Environment(\.appTheme) private var appTheme
    let text: String
    let icon: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(AppFonts.ui(26)).foregroundStyle(appTheme.muted)
            Text(text).foregroundStyle(appTheme.muted).font(AppFonts.ui(14))
        }
    }
}

struct SessionStatusIndicator: View {
    @Environment(\.appTheme) private var appTheme
    let active: Bool
    let selected: Bool
    let loaded: Bool
    let finishedUnseen: Bool

    var body: some View {
        ZStack {
            if active {
                if !selected {
                    SignalMarch(presentation: .compact)
                        .help("Working")
                }
            } else if finishedUnseen {
                Image(systemName: "checkmark.circle.fill")
                    .font(AppFonts.ui(10.5, weight: .semibold))
                    .foregroundStyle(appTheme.good)
                    .help("Finished while away")
            } else if loaded {
                Circle()
                    .fill(appTheme.brass.opacity(0.86))
                    .frame(width: 6, height: 6)
                    .help("Runtime loaded")
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if active { return "Working" }
        if finishedUnseen { return "Finished while away" }
        if loaded { return "Runtime loaded" }
        return "Idle"
    }
}

struct InlineIconButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.ui(12, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? appTheme.brass : appTheme.muted)
            .frame(width: 24, height: 22)
    }
}
