import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let pigToggleSidebar = Notification.Name("pigToggleSidebar")
    static let pigRevealSidebarSearch = Notification.Name("pigRevealSidebarSearch")
}

struct RootView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var sidebarWidth: CGFloat = SidebarPreference.width
    @State private var sidebarSearchRequest: UUID?
    @State private var sidebarAutoCollapsedForCompact = false
    @State private var sidebarHoverRevealed = false
    @State private var sidebarRevealWorkItem: DispatchWorkItem?
    @State private var chatInsetActive = false
    @State private var chatInsetCommitGeneration = 0
    @State private var renameText = ""

    private let minSidebarWidth: CGFloat = 238
    private let maxSidebarWidth: CGFloat = 520
    private let minChatWidth: CGFloat = 620
    /// Hit-target only; overlaid on the sidebar edge so it does not open a visual gap.
    private let resizeHandleWidth: CGFloat = 6
    private let sidebarRevealEdgeWidth: CGFloat = 18
    private let sidebarRevealButtonClearance: CGFloat = 58
    private let sidebarAnimationDuration: TimeInterval = 0.22
    private var sidebarAnimation: Animation { .smooth(duration: sidebarAnimationDuration, extraBounce: 0) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.sanitizedForLayout
            let compact = shouldUseSidebarDrawer(width: size.width)
            let drawerWidth = drawerWidth(for: size.width)
            let clampedSidebarWidth = min(max(sidebarWidth, minSidebarWidth), maxSidebarWidth)
            let showInlineSidebar = !compact && model.sidebarVisible
            let inlineSurfaceWidth = clampedSidebarWidth
            // The chat pane's layout width must change in a single step
            // (immediately on collapse, at slide-end on expand) so the message
            // history re-wraps once instead of on every animation frame.
            let chatInset = (chatInsetActive && showInlineSidebar) ? inlineSurfaceWidth : 0
            let showHoverDrawer = !model.sidebarVisible && sidebarHoverRevealed
            let showCompactDrawer = compact && model.sidebarVisible
            let showDrawerSurface = compact || !model.sidebarVisible
            let showDrawer = showHoverDrawer || showCompactDrawer

            ZStack(alignment: .topLeading) {
                ChatPaneView(controller: model.selectedController)
                    .frame(width: max(1, size.width - chatInset), height: size.height, alignment: .topLeading)
                    .offset(x: chatInset)
                    .animation(nil, value: chatInset)
                    .zIndex(1)

                if !compact {
                    ZStack(alignment: .trailing) {
                        SidebarView(searchRequest: showInlineSidebar ? sidebarSearchRequest : nil)
                            .frame(width: clampedSidebarWidth, height: size.height, alignment: .topLeading)
                        SidebarResizeHandle(
                            width: $sidebarWidth,
                            minWidth: minSidebarWidth,
                            maxWidth: max(minSidebarWidth, min(maxSidebarWidth, size.width - minChatWidth))
                        )
                        .frame(width: resizeHandleWidth, height: size.height)
                        .offset(x: resizeHandleWidth / 2)
                    }
                    .frame(width: inlineSurfaceWidth, height: size.height, alignment: .topLeading)
                    .compositingGroup()
                    .offset(x: showInlineSidebar ? 0 : -inlineSurfaceWidth)
                    .animation(sidebarAnimation, value: showInlineSidebar)
                    .allowsHitTesting(showInlineSidebar)
                    .zIndex(2)
                }

                if !model.sidebarVisible {
                    Rectangle()
                        .fill(Color.black.opacity(0.001))
                        .contentShape(Rectangle())
                        .frame(width: sidebarRevealEdgeWidth, height: max(0, size.height - sidebarRevealButtonClearance))
                        .offset(y: sidebarRevealButtonClearance)
                        .onHover { hovering in
                            if hovering {
                                scheduleSidebarReveal()
                            } else {
                                cancelPendingSidebarReveal()
                            }
                        }
                        .zIndex(3)
                }

                if compact {
                    Color.black.opacity(model.sidebarVisible ? 0.32 : 0)
                        .contentShape(Rectangle())
                        .allowsHitTesting(model.sidebarVisible)
                        .onTapGesture {
                            setSidebarVisible(false)
                        }
                        .animation(sidebarAnimation, value: model.sidebarVisible)
                        .zIndex(5)
                }

                if showDrawerSurface {
                    SidebarView(searchRequest: showDrawer ? sidebarSearchRequest : nil)
                        .frame(width: drawerWidth, height: size.height, alignment: .topLeading)
                        .background(appTheme.panel)
                        .shadow(color: Color.black.opacity(0.42), radius: showDrawer ? 24 : 0, x: 8, y: 0)
                        .offset(x: showDrawer ? 0 : -drawerWidth - 28)
                        .opacity(showDrawer ? 1 : 0)
                        .compositingGroup()
                        .animation(sidebarAnimation, value: showDrawer)
                        .allowsHitTesting(showDrawer)
                        .onHover { hovering in
                            if !hovering, !model.sidebarVisible {
                                withAnimation(sidebarAnimation) {
                                    sidebarHoverRevealed = false
                                }
                            }
                        }
                        .zIndex(6)
                }

                VStack(alignment: .trailing, spacing: 8) {
                    PiMaintenanceHost(controller: model.piMaintenance, theme: model.selectedTheme)
                    UnifiedGlobalToast()
                }
                .padding(.top, 16)
                .padding(.trailing, 16)
                .frame(width: size.width, height: size.height, alignment: .topTrailing)
                .zIndex(10)

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
            .onAppear {
                syncSidebarVisibilityForCompact(compact)
                chatInsetActive = !compact && model.sidebarVisible
            }
            .onChange(of: showInlineSidebar) { _, inline in scheduleChatInsetCommit(inline: inline) }
            .onChange(of: compact) { _, isCompact in syncSidebarVisibilityForCompact(isCompact) }
            .onReceive(NotificationCenter.default.publisher(for: .pigRevealSidebarSearch)) { _ in
                model.sidebarMode = .sessions
                setSidebarVisible(true)
                sidebarSearchRequest = UUID()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pigToggleSidebar)) { _ in
                setSidebarVisible(!model.sidebarVisible)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                cancelPendingSidebarReveal()
                hideCollapsedSidebarDrawerIfNeeded(compact: compact)
            }
            .onDisappear {
                cancelPendingSidebarReveal()
            }
        }
        .background(appTheme.background)
        .font(AppFonts.ui(14))
        .onChange(of: sidebarWidth) { _, width in
            SidebarPreference.width = min(max(width, minSidebarWidth), maxSidebarWidth)
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

    private func shouldUseSidebarDrawer(width: CGFloat) -> Bool {
        width < sidebarWidth + minChatWidth
    }

    private func drawerWidth(for windowWidth: CGFloat) -> CGFloat {
        max(1, min(sidebarWidth, max(minSidebarWidth, windowWidth - 76)))
    }

    private func scheduleChatInsetCommit(inline: Bool) {
        chatInsetCommitGeneration += 1
        if inline {
            let generation = chatInsetCommitGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + sidebarAnimationDuration + 0.03) {
                guard generation == chatInsetCommitGeneration else { return }
                chatInsetActive = true
            }
        } else {
            chatInsetActive = false
        }
    }

    private func setSidebarVisible(_ visible: Bool) {
        cancelPendingSidebarReveal()
        sidebarAutoCollapsedForCompact = false
        sidebarHoverRevealed = false
        withAnimation(sidebarAnimation) {
            model.sidebarVisible = visible
        }
    }

    private func scheduleSidebarReveal() {
        guard NSApp.isActive, !model.sidebarVisible, !sidebarHoverRevealed else { return }
        cancelPendingSidebarReveal()
        let workItem = DispatchWorkItem {
            guard NSApp.isActive, !model.sidebarVisible else { return }
            withAnimation(sidebarAnimation) {
                sidebarHoverRevealed = true
            }
        }
        sidebarRevealWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func cancelPendingSidebarReveal() {
        sidebarRevealWorkItem?.cancel()
        sidebarRevealWorkItem = nil
    }

    private func syncSidebarVisibilityForCompact(_ compact: Bool) {
        if compact, model.sidebarVisible, !sidebarAutoCollapsedForCompact {
            sidebarAutoCollapsedForCompact = true
            model.sidebarVisible = false
        } else if !compact, sidebarAutoCollapsedForCompact {
            sidebarAutoCollapsedForCompact = false
            model.sidebarVisible = true
        }
    }

    private func hideCollapsedSidebarDrawerIfNeeded(compact: Bool) {
        guard sidebarHoverRevealed || (compact && model.sidebarVisible) else { return }
        withAnimation(sidebarAnimation) {
            sidebarHoverRevealed = false
            if compact, model.sidebarVisible {
                sidebarAutoCollapsedForCompact = true
                model.sidebarVisible = false
            }
        }
    }
}

private extension CGSize {
    var sanitizedForLayout: CGSize {
        CGSize(width: max(1, width.isFinite ? width : 1), height: max(1, height.isFinite ? height : 1))
    }
}

struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat
    @State private var startingWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() }
                else { NSCursor.pop() }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = startingWidth ?? width
                        startingWidth = start
                        width = min(max(minWidth, start + value.translation.width), maxWidth)
                    }
                    .onEnded { _ in startingWidth = nil }
            )
    }
}

struct SidebarView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let searchRequest: UUID?

    var body: some View {
        VStack(spacing: 0) {
            SessionsSidebarContent(searchRequest: searchRequest)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(appTheme.panel)
    }
}

struct SidebarModeSwitcher: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 0) {
                ForEach(AppModel.SidebarMode.allCases) { mode in
                    let selected = model.sidebarMode == mode
                    Button {
                        model.sidebarMode = mode
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: mode == .sessions ? "bubble.left.and.bubble.right" : "folder")
                                .foregroundStyle(selected ? appTheme.brass : appTheme.muted)
                            Text(mode.rawValue)
                        }
                        .font(AppFonts.ui(12))
                        .foregroundStyle(selected ? appTheme.text : appTheme.muted)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(35, AppFonts.scaled(35)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        if mode == .sessions {
                            Button {
                                model.refreshSessions()
                            } label: {
                                Label("Refresh Sessions", systemImage: "arrow.clockwise")
                            }
                            Divider()
                            Button {
                                model.showingPiResources = true
                            } label: {
                                Label("Extensions & Resources", systemImage: "puzzlepiece.extension")
                            }
                            Button {
                                model.addExistingProject()
                            } label: {
                                Label("Add Existing Project", systemImage: "folder.badge.plus")
                            }
                            Button {
                                model.createProject()
                            } label: {
                                Label("Create Project Directory", systemImage: "plus.square")
                            }
                        }
                    }
                }
                }
                .background {
                    GeometryReader { geometry in
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(appTheme.panel2)
                            .overlay {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(appTheme.line, lineWidth: 1)
                            }
                            .frame(width: geometry.size.width / 2)
                            .offset(x: model.sidebarMode == .sessions ? 0 : geometry.size.width / 2)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: model.sidebarMode)
                    }
                }
                .padding(3)
                .background(appTheme.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
        }
    }
}

struct SessionsSidebarContent: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let searchRequest: UUID?
    @State private var searchVisible = false
    @State private var searchText = ""
    @State private var archiveSearchText = ""
    @State private var showingArchive = false
    @State private var archiveProjectPath: String?
    @State private var draggingInboxItemID: String?
    @State private var inboxDropTargetID: String?
    @State private var inboxDropAfter = false
    @State private var revealedInboxItemID: String?
    @FocusState private var searchFocused: Bool

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var resolvedInboxIDs: [String] {
        model.sessionInboxIDs.filter { model.inboxController(for: $0) != nil || model.inboxSummary(for: $0) != nil }
    }

    private func inboxText(for itemID: String) -> String {
        if let controller = model.inboxController(for: itemID) {
            return "\(controller.title) \(controller.projectName)".lowercased()
        }
        guard let summary = model.inboxSummary(for: itemID) else { return "" }
        return "\(summary.title) \(model.projectDisplayName(for: summary.projectPath))".lowercased()
    }

    private var visibleInboxIDs: [String] {
        guard !normalizedSearch.isEmpty else { return resolvedInboxIDs }
        var included = Set(resolvedInboxIDs.filter { inboxText(for: $0).contains(normalizedSearch) })
        for itemID in included {
            if let parentID = model.inboxParentID(for: itemID) { included.insert(parentID) }
        }
        return resolvedInboxIDs.filter { included.contains($0) }
    }

    private var rootInboxIDs: [String] {
        let visible = Set(visibleInboxIDs)
        return visibleInboxIDs.filter { itemID in
            guard let parentID = model.inboxParentID(for: itemID) else { return true }
            return !visible.contains(parentID)
        }
    }

    private func visibleChildren(of parentID: String) -> [String] {
        visibleInboxIDs.filter { model.inboxParentID(for: $0) == parentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            SidebarModeSwitcher()
            if model.sidebarMode == .files {
                FilesSidebarContent()
            } else {
            if searchVisible || !searchText.isEmpty || !archiveSearchText.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(AppFonts.ui(11, weight: .semibold))
                        .foregroundStyle(appTheme.muted)
                    TextField(
                        showingArchive ? "Search archive" : "Search sessions",
                        text: showingArchive ? $archiveSearchText : $searchText
                    )
                        .textFieldStyle(.plain)
                        .foregroundStyle(appTheme.text)
                        .focused($searchFocused)
                        .frame(minHeight: 22)
                        .onAppear {
                            searchFocused = true
                        }
                        .onExitCommand {
                            searchText = ""
                            archiveSearchText = ""
                            searchFocused = false
                            searchVisible = false
                        }
                    if showingArchive ? !archiveSearchText.isEmpty : !searchText.isEmpty {
                        Button {
                            if showingArchive { archiveSearchText = "" }
                            else { searchText = "" }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(appTheme.muted)
                        .accessibilityLabel("Clear search")
                    }
                }
                .modifier(SearchFieldSurface(isFocused: searchFocused))
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            ZStack {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rootInboxIDs, id: \.self) { itemID in
                            InboxSessionItemRow(
                                itemID: itemID,
                                isChild: model.inboxParentID(for: itemID) != nil,
                                draggingItemID: $draggingInboxItemID,
                                dropTargetID: $inboxDropTargetID,
                                dropAfter: $inboxDropAfter,
                                revealedItemID: $revealedInboxItemID,
                                reorderingEnabled: normalizedSearch.isEmpty
                            )
                            ForEach(visibleChildren(of: itemID), id: \.self) { childID in
                                InboxSessionItemRow(
                                    itemID: childID,
                                    isChild: true,
                                    draggingItemID: $draggingInboxItemID,
                                    dropTargetID: $inboxDropTargetID,
                                    dropAfter: $inboxDropAfter,
                                    revealedItemID: $revealedInboxItemID,
                                    reorderingEnabled: normalizedSearch.isEmpty
                                )
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
                .opacity(showingArchive ? 0 : 1)
                .allowsHitTesting(!showingArchive)

                if !showingArchive && rootInboxIDs.isEmpty {
                    if normalizedSearch.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray")
                                .font(AppFonts.ui(26))
                            Text("No open sessions")
                                .font(AppFonts.ui(12))
                        }
                        .foregroundStyle(appTheme.muted)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 8) {
                            Text("No sessions match “\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))”")
                                .font(AppFonts.ui(12.5))
                                .foregroundStyle(appTheme.muted)
                                .multilineTextAlignment(.center)
                            Button("Search archive") {
                                archiveSearchText = searchText
                                archiveProjectPath = nil
                                showingArchive = true
                                model.loadSessionArchive()
                            }
                            .font(AppFonts.ui(12.5))
                            .foregroundStyle(appTheme.brass)
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                if showingArchive {
                    SessionArchiveContent(searchText: archiveSearchText, selectedProjectPath: $archiveProjectPath) {
                        archiveSearchText = ""
                        archiveProjectPath = nil
                        showingArchive = false
                    }
                    .background(appTheme.panel)
                }
            }
            }
            sidebarActions
        }
        .onChange(of: searchRequest, initial: true) { _, request in
            if request != nil { revealSearch() }
        }
    }

    private var sidebarActions: some View {
        HStack(spacing: 2) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(appTheme.muted)
            .help("Open Settings")
            .accessibilityLabel("Open Settings")
            Spacer(minLength: 0)
            AppUpdateButton(updates: model.appUpdates)
            SidebarUpdateButton(maintenance: model.piMaintenance)
            Button {
                model.undoLastInboxDismissal()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(model.canUndoInboxDismissal ? appTheme.secondaryText : appTheme.muted.opacity(0.4))
            .disabled(!model.canUndoInboxDismissal)
            .help(model.inboxDismissalUndoTitle.map { "Undo Done: \($0)" } ?? "Nothing to undo")
            .accessibilityLabel("Undo last marked-done thread")
            Button(action: revealSearch) {
                Image(systemName: "magnifyingglass")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(searchVisible ? appTheme.text : appTheme.muted)
            .help("Search sessions (⌘F)")
            .accessibilityLabel("Search sessions")
            Button {
                model.sidebarMode = .sessions
                archiveSearchText = ""
                archiveProjectPath = nil
                showingArchive = true
                model.loadSessionArchive()
            } label: {
                Image(systemName: "archivebox")
                    .frame(width: 26, height: 28)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(showingArchive ? appTheme.text : appTheme.muted)
            .help("Browse session archive")
            .accessibilityLabel("Browse session archive")
        }
        .font(AppFonts.ui(11.5, weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func revealSearch() {
        model.sidebarMode = .sessions
        searchVisible = true
        searchFocused = true
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
private struct AppUpdateButton: View {
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

/// Small colorful affordance for Pi / extension updates, immediately left of
/// the Undo button. Opens the existing update review sheet; changelog and
/// update actions live there. When only the installed notice remains (nothing
/// to download), it shows an info icon that opens the changelog instead.
private struct SidebarUpdateButton: View {
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

private struct InboxSessionItemRow: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let itemID: String
    let isChild: Bool
    @Binding var draggingItemID: String?
    @Binding var dropTargetID: String?
    @Binding var dropAfter: Bool
    @Binding var revealedItemID: String?
    let reorderingEnabled: Bool

    var body: some View {
        Group {
            if let controller = model.inboxController(for: itemID) {
                InboxControllerRow(
                    itemID: itemID,
                    controller: controller,
                    isChild: isChild,
                    revealedItemID: $revealedItemID
                )
            } else if let summary = model.inboxSummary(for: itemID) {
                InboxSummaryRow(
                    itemID: itemID,
                    summary: summary,
                    isChild: isChild,
                    revealedItemID: $revealedItemID
                )
            }
        }
        .opacity(draggingItemID == itemID ? 0.45 : 1)
        .overlay(alignment: dropAfter ? .bottom : .top) {
            if dropTargetID == itemID, draggingItemID != itemID {
                Rectangle()
                    .fill(appTheme.brass)
                    .frame(height: 2)
                    .padding(.leading, isChild ? 34 : 12)
                    .padding(.trailing, 10)
                    .shadow(color: appTheme.brass.opacity(0.35), radius: 3)
            }
        }
        .onDrag {
            guard reorderingEnabled else { return NSItemProvider() }
            draggingItemID = itemID
            dropTargetID = nil
            return NSItemProvider(object: itemID as NSString)
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: InboxItemDropDelegate(
                targetID: itemID,
                draggingItemID: $draggingItemID,
                dropTargetID: $dropTargetID,
                dropAfter: $dropAfter,
                model: model,
                enabled: reorderingEnabled
            )
        )
    }
}

private struct InboxControllerRow: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var controller: SessionController
    let itemID: String
    let isChild: Bool
    @Binding var revealedItemID: String?

    init(itemID: String, controller: SessionController, isChild: Bool, revealedItemID: Binding<String?>) {
        self.itemID = itemID
        self.controller = controller
        self.isChild = isChild
        self._revealedItemID = revealedItemID
    }

    var body: some View {
        InboxSessionListRow(
            title: controller.title.isEmpty ? (controller.isQuickChat ? "Quick Chat" : "Untitled") : controller.title,
            projectName: controller.projectName,
            quickChat: controller.isQuickChat,
            selected: model.selectedControllerID == controller.id,
            working: controller.showsActivityIndicator,
            loaded: controller.isProcessActive,
            finishedUnseen: model.finishedUnseen(controller),
            isChild: isChild,
            itemID: itemID,
            revealedItemID: $revealedItemID,
            done: { model.markInboxItemDone(itemID) },
            action: { model.selectController(controller) }
        )
        .contextMenu {
            Button("Done", systemImage: "checkmark") {
                revealedItemID = nil
                model.markInboxItemDone(itemID)
            }
            .disabled(controller.showsActivityIndicator)
            Divider()
            if controller.isQuickChat {
                QuickChatContextMenu(controller: controller)
            } else {
                ControllerSessionContextMenu(controller: controller)
            }
        }
    }
}

private struct InboxSummaryRow: View {
    @EnvironmentObject private var model: AppModel
    let itemID: String
    let summary: SessionSummary
    let isChild: Bool
    @Binding var revealedItemID: String?

    var body: some View {
        InboxSessionListRow(
            title: summary.title,
            projectName: URL(fileURLWithPath: summary.projectPath).lastPathComponent,
            quickChat: model.isQuickChatInboxItem(itemID),
            selected: model.selectedController?.sessionPath == summary.filePath,
            working: model.activeController(forSessionPath: summary.filePath) != nil,
            loaded: model.loadedController(forSessionPath: summary.filePath) != nil,
            finishedUnseen: model.finishedUnseen(forSessionPath: summary.filePath),
            isChild: isChild,
            itemID: itemID,
            revealedItemID: $revealedItemID,
            done: { model.markInboxItemDone(itemID) },
            action: { model.selectSession(summary) }
        )
        .contextMenu {
            Button("Done", systemImage: "checkmark") {
                revealedItemID = nil
                model.markInboxItemDone(itemID)
            }
            .disabled(model.activeController(forSessionPath: summary.filePath) != nil)
            Divider()
            SessionSummaryContextMenu(summary: summary)
        }
    }
}

private struct InboxSessionListRow: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    let title: String
    let projectName: String
    let quickChat: Bool
    let selected: Bool
    let working: Bool
    let loaded: Bool
    let finishedUnseen: Bool
    let isChild: Bool
    let itemID: String
    @Binding var revealedItemID: String?
    let done: () -> Void
    let action: () -> Void
    @State private var revealAmount: CGFloat = 0
    @State private var interactionStartAmount: CGFloat = 0
    @State private var suppressSelection = false
    @FocusState private var doneFocused: Bool

    private let actionWidth: CGFloat = 78

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let doneRevealed = revealedItemID == itemID && revealAmount > 0
            ZStack(alignment: .trailing) {
                Button(action: complete) {
                    HStack(spacing: 5) {
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(AppFonts.ui(10.5, weight: .semibold))
                        Text("Done")
                            .font(AppFonts.ui(11, weight: .medium))
                    }
                    .padding(.trailing, 15)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(
                        revealAmount >= width * 0.6
                            ? appTheme.good
                            : appTheme.good.opacity(0.14)
                    )
                    .foregroundStyle(revealAmount >= width * 0.6 ? appTheme.panel : appTheme.good)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(working || !doneRevealed)
                .allowsHitTesting(doneRevealed && !working)
                .focused($doneFocused)
                .accessibilityLabel("Mark \(title) done")
                .accessibilityHidden(!doneRevealed)
                .onExitCommand(perform: closeReveal)

                Button {
                    guard !suppressSelection else { return }
                    if revealedItemID == itemID {
                        closeReveal()
                    } else {
                        action()
                    }
                } label: {
                    rowFace
                }
                .buttonStyle(.plain)
                .offset(x: -revealAmount)
                .accessibilityLabel("\(title), \(projectName)")
                .accessibilityValue("\(loaded ? "Loaded" : "Unloaded"), \(working ? "working" : finishedUnseen ? "new reply" : "idle")")
                .accessibilityHint(working ? "Working sessions stay in the inbox." : "Swipe left or press Delete to reveal Done.")
                .onKeyPress(.delete) {
                    revealForKeyboard()
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    revealForKeyboard()
                    return .handled
                }
                .onExitCommand(perform: closeReveal)
            }
            .background {
                SidebarSwipeEventView { event in
                    handleSwipe(event, rowWidth: width)
                }
            }
        }
        .frame(height: max(quickChat ? 55 : 72, AppFonts.scaled(quickChat ? 55 : 72)))
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .onChange(of: revealedItemID) { _, revealed in
            if revealed != itemID {
                doneFocused = false
                if revealAmount != 0 {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        revealAmount = 0
                    }
                }
            }
        }
    }

    private var rowFace: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if quickChat {
                        Image(systemName: "bolt.fill")
                            .font(AppFonts.ui(10.5, weight: .semibold))
                            .foregroundStyle(appTheme.brass)
                    }
                    Text(title)
                        .font(AppFonts.ui(13.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected || loaded ? appTheme.text : appTheme.muted)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                if !quickChat {
                    Text(projectName)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(loaded ? appTheme.secondaryText.opacity(0.72) : appTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Group {
                if working && !selected {
                    SignalMarch(presentation: .compact)
                        .help("Working")
                } else if finishedUnseen {
                    Circle()
                        .fill(appTheme.good)
                        .frame(width: 6, height: 6)
                        .shadow(color: appTheme.good.opacity(0.25), radius: 3)
                        .help("New reply")
                }
            }
            .frame(width: 30, height: 23)
        }
        .padding(.leading, isChild ? 27 : 7)
        .padding(.trailing, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            appTheme.panel
                .overlay(selected ? appTheme.brass.opacity(0.10) : Color.clear)
        }
        .overlay(alignment: .leading) {
            if selected {
                Rectangle()
                    .fill(appTheme.brass)
                    .frame(width: 2)
            }
        }
        .contentShape(Rectangle())
    }

    private func revealForKeyboard() {
        guard !working else {
            model.statusLine = "A working session cannot be marked done."
            return
        }
        revealedItemID = itemID
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            revealAmount = actionWidth
        }
        DispatchQueue.main.async { doneFocused = true }
    }

    private func closeReveal() {
        doneFocused = false
        if revealedItemID == itemID { revealedItemID = nil }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            revealAmount = 0
        }
    }

    private func complete() {
        guard !working else {
            model.statusLine = "A working session cannot be marked done."
            return
        }
        revealedItemID = nil
        done()
    }

    private func handleSwipe(_ event: SidebarSwipeEvent, rowWidth: CGFloat) {
        switch event {
        case .began:
            interactionStartAmount = revealedItemID == itemID ? revealAmount : 0
            suppressSelection = false
        case .changed(let translation):
            guard !working else {
                model.statusLine = "A working session cannot be marked done."
                return
            }
            revealedItemID = itemID
            revealAmount = min(rowWidth, max(0, interactionStartAmount + translation))
        case .ended:
            suppressSelection = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { suppressSelection = false }
            guard !working else {
                closeReveal()
                return
            }
            if revealAmount >= rowWidth * 0.6 {
                complete()
            } else if revealAmount > 32 {
                revealedItemID = itemID
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                    revealAmount = actionWidth
                }
            } else {
                closeReveal()
            }
        case .cancelled:
            closeReveal()
        }
    }
}

private enum SidebarSwipeEvent {
    case began
    case changed(CGFloat)
    case ended
    case cancelled
}

private struct SidebarSwipeEventView: NSViewRepresentable {
    let onEvent: (SidebarSwipeEvent) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onEvent = onEvent
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var view: NSView?
        var onEvent: (SidebarSwipeEvent) -> Void
        private var monitor: Any?
        private var mouseOrigin: NSPoint?
        private var mouseSwiping = false
        private var trackpadTranslation: CGFloat = 0
        private var trackpadActive = false
        private var deferredEnd: DispatchWorkItem?

        init(onEvent: @escaping (SidebarSwipeEvent) -> Void) {
            self.onEvent = onEvent
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        deinit { stop() }

        func stop() {
            deferredEnd?.cancel()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func contains(_ event: NSEvent) -> Bool {
            guard let view, event.window === view.window else { return false }
            return view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            switch event.type {
            case .leftMouseDown:
                guard contains(event) else { return event }
                mouseOrigin = event.locationInWindow
                mouseSwiping = false
            case .leftMouseDragged:
                guard let origin = mouseOrigin else { return event }
                let dx = event.locationInWindow.x - origin.x
                let dy = event.locationInWindow.y - origin.y
                if !mouseSwiping {
                    if abs(dy) > 8, abs(dy) > abs(dx) {
                        mouseOrigin = nil
                        return event
                    }
                    guard abs(dx) > 6, abs(dx) > abs(dy) else { return event }
                    mouseSwiping = true
                    onEvent(.began)
                }
                onEvent(.changed(-dx))
                return nil
            case .leftMouseUp:
                guard mouseOrigin != nil else { return event }
                mouseOrigin = nil
                if mouseSwiping {
                    mouseSwiping = false
                    onEvent(.ended)
                }
            case .scrollWheel:
                let phase = event.phase
                if trackpadActive, phase.contains(.ended) || phase.contains(.cancelled) {
                    endTrackpad(cancelled: phase.contains(.cancelled))
                    return nil
                }
                guard event.hasPreciseScrollingDeltas,
                      event.momentumPhase.isEmpty,
                      contains(event),
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                      abs(event.scrollingDeltaX) > 0.5 else { return event }
                if !trackpadActive {
                    trackpadActive = true
                    trackpadTranslation = 0
                    onEvent(.began)
                }
                trackpadTranslation -= event.scrollingDeltaX
                onEvent(.changed(trackpadTranslation))
                if phase.isEmpty { scheduleTrackpadEnd() }
                return nil
            default:
                break
            }
            return event
        }

        private func scheduleTrackpadEnd() {
            deferredEnd?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.endTrackpad(cancelled: false) }
            deferredEnd = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func endTrackpad(cancelled: Bool) {
            guard trackpadActive else { return }
            deferredEnd?.cancel()
            deferredEnd = nil
            trackpadActive = false
            onEvent(cancelled ? .cancelled : .ended)
        }
    }
}

private struct InboxItemDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggingItemID: String?
    @Binding var dropTargetID: String?
    @Binding var dropAfter: Bool
    let model: AppModel
    let enabled: Bool

    func dropEntered(info: DropInfo) {
        updateTarget(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return enabled ? DropProposal(operation: .move) : nil
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard enabled, let draggingItemID, draggingItemID != targetID else {
            clearDrag()
            return false
        }
        model.moveInboxItem(draggingItemID, relativeTo: targetID, after: dropAfter)
        clearDrag()
        return true
    }

    private func updateTarget(_ info: DropInfo) {
        guard enabled, let draggingItemID, draggingItemID != targetID else { return }
        let draggedParent = model.inboxParentID(for: draggingItemID)
        let targetParent = model.inboxParentID(for: targetID)
        let valid = draggedParent == nil && targetParent == nil
            || draggedParent != nil && draggedParent == targetParent
        guard valid else {
            if dropTargetID == targetID { dropTargetID = nil }
            return
        }
        dropTargetID = targetID
        dropAfter = info.location.y > 24
    }

    private func clearDrag() {
        draggingItemID = nil
        dropTargetID = nil
        dropAfter = false
    }
}

private struct SessionArchiveMonthGroup: Identifiable {
    let month: Date
    let sessions: [SessionSummary]
    var id: Date { month }

    var title: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: month).uppercased()
    }
}

private struct SessionArchiveProjectGroup: Identifiable {
    let projectPath: String
    let sessions: [SessionSummary]
    var id: String { projectPath }
}

private enum SessionArchiveSearchItem: Identifiable {
    case project(SessionArchiveProjectGroup)
    case session(SessionSummary)

    var id: String {
        switch self {
        case .project(let group): return "project:\(group.projectPath)"
        case .session(let session): return "session:\(session.filePath)"
        }
    }
}

struct SessionArchiveContent: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let searchText: String
    @Binding var selectedProjectPath: String?
    let close: () -> Void
    var isProjectHistory = false
    @State private var collapsedSearchProjectPaths: Set<String> = []

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var archiveProjectPaths: [String] {
        let available: Set<String> = Set(model.archivedSessionsByProject.compactMap { path, sessions -> String? in
            guard !model.isQuickChatsProject(path), sessions.contains(where: { !$0.isChildSession }) else { return nil }
            return path
        })
        let registered = model.projects.map(\.path).filter { available.contains($0) }
        let registeredSet = Set(registered)
        let unregistered = available
            .filter { !registeredSet.contains($0) }
            .sorted { model.projectDisplayName(for: $0).localizedStandardCompare(model.projectDisplayName(for: $1)) == .orderedAscending }
        return registered + unregistered
    }

    private var rootSessions: [SessionSummary] {
        if let selectedProjectPath {
            return rootSessions(for: selectedProjectPath)
        }
        return archiveProjectPaths
            .flatMap { rootSessions(for: $0) }
            .sorted { $0.timestamp > $1.timestamp }
    }

    private var filteredSessions: [SessionSummary] {
        guard !normalizedSearch.isEmpty else { return rootSessions }
        return rootSessions.filter { $0.title.lowercased().contains(normalizedSearch) }
    }

    private var monthGroups: [SessionArchiveMonthGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: rootSessions) { session in
            let components = calendar.dateComponents([.year, .month], from: session.timestamp)
            return calendar.date(from: components) ?? calendar.startOfDay(for: session.timestamp)
        }
        return grouped.keys.sorted(by: >).map { month in
            SessionArchiveMonthGroup(month: month, sessions: grouped[month] ?? [])
        }
    }

    private var searchProjectGroups: [SessionArchiveProjectGroup] {
        archiveProjectPaths.compactMap { path in
            let matches = rootSessions(for: path).filter { $0.title.lowercased().contains(normalizedSearch) }
            guard !matches.isEmpty else { return nil }
            return SessionArchiveProjectGroup(projectPath: path, sessions: matches)
        }
    }

    private var searchItems: [SessionArchiveSearchItem] {
        searchProjectGroups.flatMap { group in
            var items: [SessionArchiveSearchItem] = [.project(group)]
            if !collapsedSearchProjectPaths.contains(group.projectPath) {
                items.append(contentsOf: group.sessions.map(SessionArchiveSearchItem.session))
            }
            return items
        }
    }

    private var hasNoSessions: Bool {
        if normalizedSearch.isEmpty { return rootSessions.isEmpty }
        if selectedProjectPath == nil { return searchProjectGroups.isEmpty }
        return filteredSessions.isEmpty
    }

    private var archiveTitle: String {
        guard let selectedProjectPath else { return "ARCHIVE" }
        return model.projectDisplayName(for: selectedProjectPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isProjectHistory { archiveHeader }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var archiveHeader: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "arrow.left")
                    .font(AppFonts.ui(10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.muted)
            .help("Back to recent sessions")

            Rectangle()
                .fill(appTheme.brass)
                .frame(width: 5, height: 5)
                .rotationEffect(.degrees(45))

            Text(archiveTitle)
                .font(AppFonts.ui(10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(appTheme.text)
                .lineLimit(1)

            Spacer(minLength: 4)

            Button { model.loadSessionArchive() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(AppFonts.ui(10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(appTheme.muted)
            .disabled(model.sessionArchiveLoadState == .loading)
            .help("Refresh archive")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(appTheme.panel2.opacity(0.25))
        .overlay(alignment: .bottom) {
            Rectangle().fill(appTheme.line).frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.sessionArchiveLoadState {
        case .idle, .loading:
            SignalMarchLoadingLabel(text: isProjectHistory ? "Loading sessions…" : "Loading archive…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if hasNoSessions {
                EmptyState(
                    text: isProjectHistory
                        ? (normalizedSearch.isEmpty ? "No sessions yet" : "No matching sessions")
                        : (normalizedSearch.isEmpty ? "Archive is empty" : "No archive matches"),
                    icon: normalizedSearch.isEmpty ? "archivebox" : "magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: normalizedSearch.isEmpty ? [.sectionHeaders] : []) {
                        if normalizedSearch.isEmpty {
                            ForEach(monthGroups) { group in
                                Section {
                                    ForEach(group.sessions) { session in
                                        SessionRow(summary: session, showsProject: selectedProjectPath == nil, archived: true)
                                    }
                                } header: {
                                    SessionArchiveMonthHeader(title: group.title)
                                }
                            }
                        } else if selectedProjectPath == nil {
                            ForEach(searchItems) { item in
                                switch item {
                                case .project(let group):
                                    SessionArchiveProjectHeader(
                                        group: group,
                                        expanded: !collapsedSearchProjectPaths.contains(group.projectPath)
                                    ) {
                                        withAnimation(.easeInOut(duration: 0.16)) {
                                            if collapsedSearchProjectPaths.contains(group.projectPath) {
                                                collapsedSearchProjectPaths.remove(group.projectPath)
                                            } else {
                                                collapsedSearchProjectPaths.insert(group.projectPath)
                                            }
                                        }
                                    }
                                case .session(let session):
                                    SessionRow(summary: session, archived: true)
                                }
                            }
                        } else {
                            ForEach(filteredSessions) { session in
                                SessionRow(summary: session, archived: true)
                            }
                        }
                    }
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func rootSessions(for projectPath: String) -> [SessionSummary] {
        let sessions = model.archivedSessionsByProject[projectPath] ?? []
        let availablePaths = Set(sessions.map(\.filePath))
        return sessions.filter { session in
            guard session.isChildSession, let parentPath = session.parentSessionPath else { return true }
            return !availablePaths.contains(parentPath)
        }
    }
}

private struct SessionArchiveProjectHeader: View {
    @EnvironmentObject private var model: AppModel
    let group: SessionArchiveProjectGroup
    let expanded: Bool
    let action: () -> Void
    @State private var hovering = false

    private var project: ProjectInfo? {
        model.projects.first { $0.path == group.projectPath }
    }

    private var title: String {
        model.projectDisplayName(for: group.projectPath)
    }

    var body: some View {
        Button(action: action) {
            SidebarSectionHeader(
                title: title,
                emphasized: model.selectedProjectPath == group.projectPath || project?.isPinned == true,
                expanded: expanded,
                hovering: hovering,
                pinned: project?.isPinned == true,
                style: model.projectHeaderStyle
            ) {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SessionArchiveMonthHeader: View {
    @Environment(\.appTheme) private var appTheme
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(AppFonts.ui(9, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(appTheme.secondaryText)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .background(appTheme.panel.opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle().fill(appTheme.line.opacity(0.8)).frame(height: 1)
        }
    }
}

/// Shared project / quick-chat header. Styles: name-only or band (top hairline).
private struct SidebarSectionHeader<Trailing: View>: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let emphasized: Bool
    let expanded: Bool
    let hovering: Bool
    var pinned: Bool = false
    let style: ProjectHeaderStyle
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(AppFonts.ui(12.5, weight: .semibold))
                .foregroundStyle(emphasized ? appTheme.text : appTheme.secondaryText)
                .lineLimit(1)
            Image(systemName: "chevron.right")
                .font(AppFonts.ui(11, weight: .semibold))
                .foregroundStyle(appTheme.muted)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .opacity(hovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.16), value: expanded)
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.leading, 12)
        .padding(.trailing, 9)
        .padding(.top, style == .band ? 10 : 8)
        .padding(.bottom, style == .band ? 5 : 6)
        .background(headerBackground)
        .overlay(alignment: .top) {
            if style == .band {
                Rectangle()
                    .fill(appTheme.line)
                    .frame(height: 1)
            }
        }
        .contentShape(Rectangle())
    }

    private var headerBackground: Color {
        if hovering { return appTheme.panel2.opacity(pinned ? 0.5 : 0.4) }
        if pinned { return appTheme.panel2.opacity(0.28) }
        return Color.clear
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
        return showsProject ? "\(model.projectDisplayName(for: summary.projectPath))   ·   \(base)" : base
    }

    var body: some View {
        SessionListRow(
            title: summary.title,
            subtitle: subtitle,
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
                        Text(subtitle)
                            .font(AppFonts.ui(11.5))
                            .foregroundStyle(appTheme.muted)
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

struct FilesSidebarContent: View {
    @EnvironmentObject private var model: AppModel

    var selectedProjectPath: String? {
        model.selectedProjectPath ?? model.projects.first?.path
    }

    var body: some View {
        VStack(spacing: 0) {
            if let selectedProjectPath {
                FileTreeView(
                    rootURL: URL(fileURLWithPath: selectedProjectPath, isDirectory: true),
                    expanded: model.expandedDirectories(forProjectPath: selectedProjectPath),
                    onExpandedChange: { model.setExpandedDirectories($0, forProjectPath: selectedProjectPath) }
                )
                .id(selectedProjectPath)
            } else {
                EmptyState(text: "Select a project", icon: "folder")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
