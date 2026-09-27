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
                TextField("Search all projects", text: $searchText)
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

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if normalizedSearch.isEmpty {
                        if showsQuickChat {
                            PopoverPickerRow(title: "Quick Chat", icon: "bolt.fill", isSelected: quickChatSelected) {
                                dismiss()
                                selectQuickChat()
                            }
                            PopoverMenuDivider()
                        }
                        ForEach(pinnedProjects) { project in projectRow(project) }
                        if !pinnedProjects.isEmpty && !recentProjects.isEmpty { PopoverMenuDivider() }
                        ForEach(recentProjects) { project in projectRow(project) }
                        if (showsQuickChat ? !menuProjects.isEmpty : !pinnedProjects.isEmpty || !recentProjects.isEmpty) {
                            PopoverMenuDivider()
                        }
                        PopoverPickerRow(title: "Add Existing Project…", icon: "folder.badge.plus") {
                            dismiss()
                            model.addExistingProject()
                        }
                        PopoverPickerRow(title: "Create Project Directory…", icon: "plus.square") {
                            dismiss()
                            model.createProject()
                        }
                    } else if searchedProjects.isEmpty {
                        Text("No matching projects")
                            .font(AppFonts.ui(12.5))
                            .foregroundStyle(appTheme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    } else {
                        ForEach(searchedProjects) { project in projectRow(project) }
                    }
                }
                .padding(.vertical, 5)
            }
        }
        .frame(width: width)
        .frame(maxHeight: 440)
        .onAppear {
            searchText = ""
            if focusSearchOnAppear {
                DispatchQueue.main.async { searchFocused = true }
            }
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
