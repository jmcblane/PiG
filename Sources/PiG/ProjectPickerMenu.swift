import SwiftUI

/// Popover content shared by project selectors. The caller owns presentation and selection behavior.
struct ProjectPickerMenu: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel

    let width: CGFloat
    var showsQuickChat = false
    var showsPinButtons = false
    var focusSearchOnAppear = true
    let isSelected: (ProjectInfo) -> Bool
    let selectProject: (String) -> Void
    var quickChatSelected = false
    var selectQuickChat: () -> Void = {}
    let dismiss: () -> Void

    @State private var searchText = ""
    @State private var pendingRemoval: Agent?
    @State private var hoveredAgentID: String?

    private var menuAgents: [Agent] {
        model.agents.filter { normalizedSearch.isEmpty || "\($0.name) \($0.role)".lowercased().contains(normalizedSearch) }
    }
    @FocusState private var searchFocused: Bool

    private var menuProjects: [ProjectInfo] {
        model.projects.filter { !model.isQuickChatsProject($0.path) }
    }

    private var pinnedProjects: [ProjectInfo] { menuProjects.filter(\.isPinned) }
    private var recentProjects: [ProjectInfo] { Array(menuProjects.filter { !$0.isPinned }.prefix(10)) }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var searchedProjects: [ProjectInfo] {
        guard !normalizedSearch.isEmpty else { return [] }
        return menuProjects
            .filter {
                $0.displayName.lowercased().contains(normalizedSearch) ||
                $0.path.lowercased().contains(normalizedSearch)
            }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.muted)
                TextField("Search projects and agents", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(AppFonts.ui(12.5))
                    .focused($searchFocused)
                    .foregroundStyle(appTheme.text)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(appTheme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(appTheme.panel2.opacity(0.65))

            PopoverMenuDivider()

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    columnHeader("Agents")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(menuAgents) { agent in agentRow(agent) }
                            if menuAgents.isEmpty {
                                emptyMessage(normalizedSearch.isEmpty ? "No agents yet" : "No matching agents")
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .frame(height: 365)
                }
                .frame(width: width / 2)
                .overlay(alignment: .trailing) {
                    Rectangle()
                        .fill(appTheme.line.opacity(0.6))
                        .frame(width: 1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    columnHeader("Projects")
                    ScrollView {
                        projectList
                            .padding(.vertical, 5)
                    }
                    .frame(height: 365)
                }
                .frame(width: width / 2)
            }

            PopoverMenuDivider()

            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    PopoverPickerRow(title: "New Pi Agent…", icon: "person.badge.plus", checkmarkColumn: false) {
                        dismiss()
                        model.requestNewAgent(backend: .pi)
                    }
                    PopoverPickerRow(title: "New Hermes Agent…", icon: "antenna.radiowaves.left.and.right", checkmarkColumn: false) {
                        dismiss()
                        model.requestNewAgent(backend: .hermes)
                    }
                }
                .frame(width: width / 2)
                VStack(spacing: 0) {
                    PopoverPickerRow(title: "Add Existing Project…", icon: "folder.badge.plus", checkmarkColumn: false) {
                        dismiss()
                        model.addExistingProject()
                    }
                    PopoverPickerRow(title: "Create Project Directory…", icon: "plus.square", checkmarkColumn: false) {
                        dismiss()
                        model.createProject()
                    }
                }
                .frame(width: width / 2)
            }
            .padding(.bottom, 5)
        }
        .frame(width: width)
        .alert("Remove \(pendingRemoval?.name ?? "Agent")?", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        ), presenting: pendingRemoval) { agent in
            Button("Remove", role: .destructive) { model.removeAgent(agent.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("The agent will be removed. Chats are kept.") }
        .onAppear {
            searchText = ""
            if focusSearchOnAppear {
                DispatchQueue.main.async { searchFocused = true }
            }
        }
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .font(AppFonts.ui(11, weight: .semibold))
            .foregroundStyle(appTheme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .accessibilityAddTraits(.isHeader)
    }

    private func emptyMessage(_ message: String) -> some View {
        Text(message)
            .font(AppFonts.ui(12.5))
            .foregroundStyle(appTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if normalizedSearch.isEmpty {
                if showsQuickChat {
                    PopoverPickerRow(title: "Quick Chat", icon: "bolt.fill", isSelected: quickChatSelected) {
                        dismiss()
                        selectQuickChat()
                    }
                    if !menuProjects.isEmpty { PopoverMenuDivider() }
                }
                ForEach(pinnedProjects) { project in projectRow(project) }
                if !pinnedProjects.isEmpty && !recentProjects.isEmpty { PopoverMenuDivider() }
                ForEach(recentProjects) { project in projectRow(project) }
                if menuProjects.isEmpty && !showsQuickChat {
                    emptyMessage("No projects yet")
                }
            } else if searchedProjects.isEmpty {
                emptyMessage("No matching projects")
            } else {
                ForEach(searchedProjects) { project in projectRow(project) }
            }
        }
    }

    private func agentRow(_ agent: Agent) -> some View {
        let selected = model.selectedAgent?.id == agent.id
        return Button {
            dismiss()
            model.selectAgent(agent.id)
        } label: {
            HStack(spacing: 8) {
                AgentAvatar(look: agent.look, size: 32)
                    .fixedSize()
                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(AppFonts.ui(12.5, weight: selected ? .semibold : .regular))
                        .foregroundStyle(appTheme.text)
                    Text(agent.role)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                Spacer(minLength: 0)
                Image(systemName: "checkmark")
                    .font(AppFonts.ui(10, weight: .bold))
                    .foregroundStyle(appTheme.brass)
                    .opacity(selected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hoveredAgentID == agent.id ? appTheme.brass.opacity(0.12) : Color.clear)
        .onHover { hovering in
            if hovering { hoveredAgentID = agent.id }
            else if hoveredAgentID == agent.id { hoveredAgentID = nil }
        }
        .accessibilityLabel(Text("\(agent.name), \(agent.role)"))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Edit…") { dismiss(); model.requestEditAgent(agent.id) }
            Button("Remove…", role: .destructive) { pendingRemoval = agent }
        }
    }

    @ViewBuilder private func projectRow(_ project: ProjectInfo) -> some View {
        if showsPinButtons {
            PopoverPickerRow(
                title: project.displayName,
                icon: project.isPinned ? "pin.fill" : "folder",
                isSelected: isSelected(project),
                action: { choose(project) }
            ) { rowHovering in
                Button {
                    model.toggleProjectPinned(project.path)
                } label: {
                    Image(systemName: project.isPinned ? "pin.fill" : "pin")
                        .font(AppFonts.ui(11, weight: .semibold))
                        .foregroundStyle(project.isPinned ? appTheme.brass : appTheme.text)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(rowHovering ? 1 : 0)
                .allowsHitTesting(rowHovering)
                .help(project.isPinned ? "Unpin project" : "Pin project")
            }
        } else {
            PopoverPickerRow(
                title: project.displayName,
                icon: project.isPinned ? "pin.fill" : "folder",
                isSelected: isSelected(project)
            ) { choose(project) }
        }
    }

    private func choose(_ project: ProjectInfo) {
        dismiss()
        selectProject(project.path)
    }
}
