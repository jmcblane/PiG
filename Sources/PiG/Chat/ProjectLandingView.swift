import SwiftUI
import AppKit
import ImageIO

struct ChatTabContent: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let controller: SessionController?
    let selectedProjectPath: String?
    let theme: AppThemeChoice
    @Binding var draft: String
    @Binding var imageAttachments: [ImageAttachment]

    var body: some View {
        VStack(spacing: 0) {
            if let controller {
                chatContent(controller)
            } else if let acp = model.selectedACPController {
                ChatScrollView(controller: acp, theme: theme)
                    .id(acp.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ACPComposerView(
                    controller: acp,
                    draft: Binding(get: { acp.draft }, set: { acp.draft = $0 }),
                    imageAttachments: Binding(get: { acp.draftImages }, set: { acp.draftImages = $0 })
                )
                .id(acp.id)
            } else if let chatID = model.selectedHermesChatID {
                if let hermes = model.selectedHermesController {
                    ChatScrollView(controller: hermes, theme: theme)
                        .id(hermes.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    HermesComposerView(controller: hermes, draft: $draft)
                        .id(hermes.id)
                } else {
                    VStack(spacing: 12) {
                        Text(model.inboxHermesChat(for: "hermes:\(chatID)")?.title ?? "Hermes chat")
                            .font(AppFonts.heading(24, weight: .semibold))
                        Text("This Hermes agent was removed. The local chat is retained, but cannot reconnect. Right-click it in the sidebar to delete the local data.")
                            .font(AppFonts.ui(13.5))
                            .foregroundStyle(appTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                NewChatHomeView(landingDraft: model.landingDraft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ExtensionWindowTitleView(
                title: controller?.extensionWindowTitle
                    ?? controller?.title
                    ?? model.selectedACPController?.title
                    ?? model.selectedAgent?.name
                    ?? "PiG"
            )
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder private func chatContent(_ controller: SessionController) -> some View {
        ChatScrollView(controller: controller, theme: theme)
            .id(controller.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Chat errors surface via the single arbitrated toast in
        // RootView plus the 'Last error' affordance near the composer.
        VStack(spacing: 0) {
            ExtensionWidgetsView(widgets: widgets(for: controller, placement: .aboveEditor))
            ExtensionStatusView(statuses: controller.extensionUIStatuses)
            if !controller.chatResources.isEmpty {
                ChatResourceChips(items: controller.chatResources)
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
            }
        }
        .frame(maxWidth: 800)
        ComposerView(controller: controller, draft: $draft, imageAttachments: $imageAttachments)
        ExtensionWidgetsView(widgets: widgets(for: controller, placement: .belowEditor))
            .padding(.top, -10)
    }

    private func widgets(for controller: SessionController, placement: ExtensionUIWidget.Placement) -> [ExtensionUIWidget] {
        controller.extensionUIWidgets.values
            .filter { $0.placement == placement }
            .sorted { $0.key < $1.key }
    }
}

/// Unified new-chat landing: a two-column launcher (scrollable destinations on the left,
/// selected destination header + recent history on the right) anchored above the composer.
private struct NewChatHomeView: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @ObservedObject var landingDraft: LandingDraft

    @State private var searchText = ""
    @State private var hoveredHeader: String?

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isQuickChatSelected: Bool {
        model.selectedAgent == nil && (model.composingQuickChat || model.selectedProjectPath.map(model.isQuickChatsProject) == true)
    }

    private var activeProjectPath: String? {
        guard model.selectedAgent == nil, !isQuickChatSelected, let path = model.selectedProjectPath else { return nil }
        return path
    }

    private var menuAgents: [Agent] {
        model.agents.filter {
            normalizedSearch.isEmpty || "\($0.name) \($0.role)".lowercased().contains(normalizedSearch)
        }
    }

    private var menuProjects: [ProjectInfo] {
        model.projects.filter { !model.isQuickChatsProject($0.path) }
    }

    private var pinnedProjects: [ProjectInfo] { menuProjects.filter(\.isPinned) }
    private var recentProjects: [ProjectInfo] { Array(menuProjects.filter { !$0.isPinned }.prefix(10)) }

    private var searchedProjects: [ProjectInfo] {
        guard !normalizedSearch.isEmpty else { return [] }
        return menuProjects
            .filter {
                $0.displayName.lowercased().contains(normalizedSearch) ||
                $0.path.lowercased().contains(normalizedSearch)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private var showQuickChatRow: Bool {
        normalizedSearch.isEmpty || "quick chat".contains(normalizedSearch)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 16)
            launcherPanel
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
                .frame(maxWidth: 760)
            composerSection
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            if model.selectedAgent == nil && model.selectedProjectPath == nil {
                model.showNewChatHome(quickChat: true)
            } else if model.selectedAgent == nil {
                model.prepareLandingDraft()
                if let path = activeProjectPath {
                    model.refreshACPSessions(forProjectPath: path)
                }
            }
        }
        .onChange(of: activeProjectPath) { _, path in
            if let path {
                model.refreshACPSessions(forProjectPath: path)
            }
        }
    }

    // MARK: - Two-column launcher

    private var launcherPanel: some View {
        HStack(spacing: 0) {
            destinationsColumn
                .frame(width: 245)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(appTheme.text.opacity(0.05))
                        .frame(width: 1)
                }
            recentColumn
                .frame(maxWidth: .infinity)
        }
        .frame(minHeight: 310, maxHeight: 540)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(appTheme.text.opacity(0.025)))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(appTheme.text.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Left column: Quick Chat, Agents, Projects

    private var destinationsColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.muted)
                TextField("Filter projects & agents", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppFonts.ui(12.5))
                    .foregroundStyle(appTheme.text)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.muted)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            Rectangle()
                .fill(appTheme.text.opacity(0.05))
                .frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if showQuickChatRow {
                        DestinationRow(
                            title: "Quick Chat",
                            icon: "bolt.fill",
                            iconColor: appTheme.warning,
                            isSelected: isQuickChatSelected
                        ) {
                            model.showNewChatHome(quickChat: true)
                            focusComposer()
                        }
                    }

                    if !menuAgents.isEmpty || normalizedSearch.isEmpty {
                        sectionHeader("Agents") {
                            headerButton("gearshape", help: "Agent settings") {
                                SettingsTab.open(.agents)
                            }
                        }
                        if menuAgents.isEmpty {
                            Text("No agents yet")
                                .font(AppFonts.ui(12))
                                .foregroundStyle(appTheme.muted)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(menuAgents) { agent in
                                agentRow(agent)
                            }
                        }
                    }

                    if !normalizedSearch.isEmpty && searchedProjects.isEmpty && menuAgents.isEmpty && !showQuickChatRow {
                        Text("No matches")
                            .font(AppFonts.ui(12.5))
                            .foregroundStyle(appTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    } else if normalizedSearch.isEmpty || !searchedProjects.isEmpty {
                        sectionHeader("Projects") {
                            headerButton("folder.badge.plus", help: "Add existing project…") {
                                model.addExistingProject()
                            }
                            headerButton("plus.square", help: "Create project directory…") {
                                model.createProject()
                            }
                        }
                        if normalizedSearch.isEmpty {
                            ForEach(pinnedProjects) { project in projectRow(project) }
                            if !pinnedProjects.isEmpty && !recentProjects.isEmpty {
                                Rectangle()
                                    .fill(appTheme.line.opacity(0.55))
                                    .frame(height: 1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            ForEach(recentProjects) { project in projectRow(project) }
                            if menuProjects.isEmpty {
                                Text("No projects yet")
                                    .font(AppFonts.ui(12))
                                    .foregroundStyle(appTheme.muted)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                        } else {
                            ForEach(searchedProjects) { project in projectRow(project) }
                        }
                    }
                }
                .padding(6)
            }
        }
    }

    private func sectionHeader<Actions: View>(_ title: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(spacing: 0) {
            Text(title)
                .font(AppFonts.ui(11, weight: .semibold))
                .foregroundStyle(appTheme.muted)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            actions()
                .opacity(hoveredHeader == title ? 1 : 0.45)
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .padding(.top, 8)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { hoveredHeader = title } else if hoveredHeader == title { hoveredHeader = nil }
        }
    }

    private func headerButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentShape(Rectangle())
        }
        .buttonStyle(InlineIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    private func agentRow(_ agent: Agent) -> some View {
        let selected = model.selectedAgent?.id == agent.id
        return DestinationAgentRow(agent: agent, isSelected: selected) {
            model.selectAgent(agent.id)
            focusComposer()
        }
        .contextMenu {
            Button("Edit…") { model.requestEditAgent(agent.id) }
            Button("Remove…", role: .destructive) { requestRemoval(agent) }
        }
    }

    private func projectRow(_ project: ProjectInfo) -> some View {
        let selected = activeProjectPath == project.path
        return DestinationRow(
            title: project.displayName,
            icon: project.isPinned ? "pin.fill" : "folder",
            iconColor: project.isPinned ? appTheme.brass : appTheme.muted,
            isSelected: selected,
            action: {
                model.showNewChatHome(projectPath: project.path)
                focusComposer()
            },
            trailing: { hovering in
                Button {
                    model.toggleProjectPinned(project.path)
                } label: {
                    Image(systemName: project.isPinned ? "pin.fill" : "pin")
                        .font(AppFonts.ui(10.5, weight: .semibold))
                        .foregroundStyle(project.isPinned ? appTheme.brass : appTheme.secondaryText)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .help(project.isPinned ? "Unpin project" : "Pin project")
                .accessibilityLabel(project.isPinned ? "Unpin project" : "Pin project")
            }
        )
    }

    private func requestRemoval(_ agent: Agent) {
        let model = model
        model.dialog = GlowDialogRequest(
            title: "Remove \(agent.name)?",
            message: "The agent will be removed. Chats are kept.",
            confirmTitle: "Remove",
            role: .destructive,
            onConfirm: { _ in model.removeAgent(agent.id) }
        )
    }

    // MARK: - Right column: Selected destination + recent history

    private var recentColumn: some View {
        VStack(spacing: 0) {
            destinationHeader
            Rectangle()
                .fill(appTheme.text.opacity(0.05))
                .frame(height: 1)
            recentHistoryContent
        }
    }

    private var destinationHeader: some View {
        HStack(spacing: 10) {
            if let agent = model.selectedAgent {
                AgentAvatar(look: agent.look, size: 28)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name)
                        .font(AppFonts.heading(15, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(1)
                    if !agent.role.isEmpty {
                        Text(agent.role)
                            .font(AppFonts.ui(11.5))
                            .foregroundStyle(appTheme.muted)
                            .lineLimit(1)
                    }
                }
            } else if isQuickChatSelected {
                Image(systemName: "bolt.fill")
                    .font(AppFonts.ui(17, weight: .semibold))
                    .foregroundStyle(appTheme.warning)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Quick Chat")
                        .font(AppFonts.heading(15, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(1)
                    Text("Temporary chat")
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                }
            } else if let path = activeProjectPath {
                Image(systemName: "folder.fill")
                    .font(AppFonts.ui(17, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.projectDisplayName(for: path))
                        .font(AppFonts.heading(15, weight: .semibold))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(1)
                    Text(path.abbreviatingHomeDirectory())
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            if !isQuickChatSelected {
                Button {
                    NotificationCenter.default.post(name: .pigOpenPalette, object: PaletteScope.sessions.rawValue)
                } label: {
                    Text("All chats ⇧⌘F")
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.brass)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var recentHistoryContent: some View {
        if let agent = model.selectedAgent {
            if agent.backend == .pi {
                let sessions = model.recentSessions(forAgentID: agent.id, limit: 10)
                if sessions.isEmpty {
                    recentEmptyState(icon: "clock", title: "No recent chats", subtitle: "Start typing below to message \(agent.name).")
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(sessions) { session in
                                CompactSessionRow(summary: session)
                            }
                        }
                        .padding(6)
                    }
                }
            } else {
                let chats = model.recentHermesChats(forAgentID: agent.id, limit: 10)
                if chats.isEmpty {
                    recentEmptyState(icon: "clock", title: "No recent chats", subtitle: "Start typing below to message \(agent.name).")
                } else {
                    ScrollView {
                        VStack(spacing: 1) {
                            ForEach(chats) { chat in
                                CompactRecentRow(title: chat.title, timestamp: chat.lastActivity.sidebarLabel) {
                                    model.selectHermesChat(agentID: agent.id, chatID: chat.id)
                                }
                            }
                        }
                        .padding(6)
                    }
                }
            }
        } else if isQuickChatSelected {
            recentEmptyState(
                icon: "bolt",
                title: "Temporary chat",
                subtitle: "Not tied to a project directory. Start typing below."
            )
        } else if let path = activeProjectPath {
            let sessions = model.recentSessions(forProjectPath: path, limit: 10)
            let acpSessions = model.recentACPSessions(forProjectPath: path, limit: 5)
            if sessions.isEmpty && acpSessions.isEmpty {
                recentEmptyState(
                    icon: "clock",
                    title: "No recent chats",
                    subtitle: "Start typing below to begin in \(model.projectDisplayName(for: path))."
                )
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(sessions) { session in
                            CompactSessionRow(summary: session)
                        }
                        ForEach(acpSessions) { session in
                            ACPRecentSessionRow(summary: session) {
                                model.openACPSession(session)
                            }
                        }
                    }
                    .padding(6)
                }
            }
        } else {
            recentEmptyState(icon: "clock", title: "Choose a destination", subtitle: "Select a project, agent, or Quick Chat on the left.")
        }
    }

    private func recentEmptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(AppFonts.ui(20, weight: .light))
                .foregroundStyle(appTheme.muted.opacity(0.75))
            Text(title)
                .font(AppFonts.ui(13, weight: .medium))
                .foregroundStyle(appTheme.secondaryText)
            Text(subtitle)
                .font(AppFonts.ui(11.5))
                .foregroundStyle(appTheme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Composer

    @ViewBuilder private var composerSection: some View {
        if let agent = model.selectedAgent, agent.backend == .hermes {
            if let controller = model.hermesLandingDraftController {
                HermesComposerView(
                    controller: controller,
                    draft: $landingDraft.text,
                    beforeSubmit: { model.activateHermesLandingDraft(controller) }
                )
                .frame(maxWidth: 760)
            } else {
                SignalMarchLoadingLabel(text: "Loading composer…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            }
        } else if let controller = model.landingDraftController {
            ComposerView(
                controller: controller,
                draft: $landingDraft.text,
                imageAttachments: $landingDraft.images,
                beforeSubmit: { model.activateLandingDraft(controller) },
                focusOnAppear: true,
                showsLandingResources: activeProjectPath != nil
            )
        } else {
            SignalMarchLoadingLabel(text: "Loading composer…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        }
    }

    private func focusComposer() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .pigFocusComposer, object: nil)
        }
    }
}

// MARK: - Destination rows

private struct DestinationRow<Trailing: View>: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let icon: String
    let iconColor: Color
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let trailing: (Bool) -> Trailing
    @State private var hovering = false

    init(
        title: String,
        icon: String,
        iconColor: Color,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder trailing: @escaping (Bool) -> Trailing
    ) {
        self.title = title
        self.icon = icon
        self.iconColor = iconColor
        self.isSelected = isSelected
        self.action = action
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(AppFonts.ui(11.5, weight: .semibold))
                        .foregroundStyle(isSelected ? iconColor : iconColor.opacity(0.85))
                        .frame(width: 18)
                    Text(title)
                        .font(AppFonts.ui(12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected || hovering ? appTheme.text : appTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(AppFonts.ui(10, weight: .bold))
                            .foregroundStyle(appTheme.brass)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 4)
                .padding(.vertical, 5.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing(hovering)
                .padding(.trailing, 4)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? appTheme.brass.opacity(0.14) : (hovering ? appTheme.panel2.opacity(0.75) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? appTheme.brass.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension DestinationRow where Trailing == EmptyView {
    init(
        title: String,
        icon: String,
        iconColor: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) {
        self.init(title: title, icon: icon, iconColor: iconColor, isSelected: isSelected, action: action) { _ in EmptyView() }
    }
}

private struct DestinationAgentRow: View {
    @Environment(\.appTheme) private var appTheme
    let agent: Agent
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AgentAvatar(look: agent.look, size: 20)
                    .fixedSize()
                Text(agent.name)
                    .font(AppFonts.ui(12.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected || hovering ? appTheme.text : appTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(AppFonts.ui(10, weight: .bold))
                        .foregroundStyle(appTheme.brass)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? appTheme.brass.opacity(0.14) : (hovering ? appTheme.panel2.opacity(0.75) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? appTheme.brass.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text("\(agent.name), \(agent.role)"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Compact recent session rows

private struct CompactSessionRow: View {
    @EnvironmentObject private var model: AppModel
    let summary: SessionSummary

    var body: some View {
        CompactRecentRow(
            title: summary.title,
            timestamp: summary.timestamp.sidebarLabel
        ) {
            model.selectSession(summary)
        }
        .contextMenu { SessionSummaryContextMenu(summary: summary) }
    }
}

private struct CompactRecentRow: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    let timestamp: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title)
                    .font(AppFonts.ui(12.5, weight: .medium))
                    .foregroundStyle(hovering ? appTheme.text : appTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(timestamp)
                    .font(AppFonts.ui(11.5))
                    .foregroundStyle(appTheme.muted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? appTheme.panel2.opacity(0.75) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ACPRecentSessionRow: View {
    @Environment(\.appTheme) private var appTheme
    let summary: ACPSessionSummary
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(TabStripPickerLabel.color(for: ACPProvider.antigravityDisplayName))
                    .frame(width: 14)
                Text(summary.title)
                    .font(AppFonts.ui(12.5, weight: .medium))
                    .foregroundStyle(hovering ? appTheme.text : appTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let updatedAt = summary.updatedAt {
                    Text(updatedAt.sidebarLabel)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? appTheme.panel2.opacity(0.75) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
