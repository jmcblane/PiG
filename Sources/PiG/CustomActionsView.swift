import SwiftUI
import AppKit

struct TitlebarCustomActionsInstaller: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { install(in: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { install(in: nsView.window) }
    }

    private func install(in window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = .hidden
        installLeftControls(in: window)
        installCenterControls(in: window)
        installCustomActions(in: window)
    }

    private func installLeftControls(in window: NSWindow) {
        let identifier = NSUserInterfaceItemIdentifier("PiG.leftTitlebarControls")
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == identifier }) else { return }

        let controls = ThemedTitlebarProjectControls()
            .environmentObject(model)
            .padding(.leading, 8)
            .frame(width: 120, height: 22, alignment: .leading)
        let hostingView = NSHostingView(rootView: controls)
        hostingView.identifier = identifier
        hostingView.frame = NSRect(x: 0, y: 0, width: 120, height: 22)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hostingView
        accessory.layoutAttribute = .left
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func installCenterControls(in window: NSWindow) {
        let identifier = NSUserInterfaceItemIdentifier("PiG.centerTitlebarControls")
        guard let titlebarView = window.standardWindowButton(.closeButton)?.superview else { return }
        guard !titlebarView.subviews.contains(where: { $0.identifier == identifier }) else { return }

        let controls = ThemedTitlebarSessionControls()
            .environmentObject(model)
            .frame(width: 280, height: 20, alignment: .center)
        let hostingView = NSHostingView(rootView: controls)
        hostingView.identifier = identifier
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        hostingView.frame = NSRect(x: 0, y: 0, width: 280, height: 20)
        titlebarView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.centerXAnchor.constraint(equalTo: titlebarView.centerXAnchor),
            hostingView.centerYAnchor.constraint(equalTo: titlebarView.centerYAnchor),
            hostingView.widthAnchor.constraint(equalToConstant: 280),
            hostingView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    private func installCustomActions(in window: NSWindow) {
        let identifier = NSUserInterfaceItemIdentifier("PiG.customActionsTitlebar")
        guard !window.titlebarAccessoryViewControllers.contains(where: { $0.view.identifier == identifier }) else { return }

        let controls = ThemedTitlebarRightControls()
            .environmentObject(model)
            .padding(.trailing, 10)
            .frame(width: 225, height: 22, alignment: .trailing)
        let hostingView = NSHostingView(rootView: controls)
        hostingView.identifier = identifier
        hostingView.frame = NSRect(x: 0, y: 0, width: 225, height: 22)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = hostingView
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }
}

private struct ThemedTitlebarProjectControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TitlebarProjectControls()
            .environment(\.appTheme, AppTheme(choice: model.selectedTheme))
    }
}

private struct ThemedTitlebarSessionControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TitlebarSessionControls()
            .environment(\.appTheme, AppTheme(choice: model.selectedTheme))
    }
}

private struct ThemedTitlebarRightControls: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            TitlebarTerminalButton()
            SessionTreeToolbarButton()
            CustomActionsToolbarButton()
        }
        .environment(\.appTheme, AppTheme(choice: model.selectedTheme))
    }
}

struct TitlebarProjectControls: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button {
                NotificationCenter.default.post(name: .pigToggleSidebar, object: nil)
            } label: {
                Image(systemName: "sidebar.left")
                    .foregroundStyle(model.sidebarVisible ? appTheme.brass : appTheme.text)
            }
            .help(model.sidebarVisible ? "Hide sidebar" : "Show sidebar")

            Button {
                model.showingPiResources = true
            } label: {
                Image(systemName: "puzzlepiece.extension")
            }
            .help("Extensions & Resources")
            .popover(isPresented: $model.showingPiResources, arrowEdge: .bottom) {
                PiResourcesPopoverView()
                    .environmentObject(model)
            }

            Button {
                model.addExistingProject()
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Add Existing Project")

            Button {
                model.createProject()
            } label: {
                Image(systemName: "plus.square")
            }
            .help("Create Project Directory")
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .fixedSize()
    }
}

private struct TitlebarIconButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.ui(12.5, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? appTheme.brass : appTheme.text)
            .frame(width: 24, height: 20)
            .background(configuration.isPressed ? appTheme.panel2.opacity(0.9) : Color.clear)
            .contentShape(Rectangle())
    }
}

private struct TitlebarTerminalButton: View {
    @State private var isSplitActive = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .pigToggleTerminal, object: nil)
        } label: {
            Image(systemName: "terminal")
        }
        .buttonStyle(TitlebarIconButtonStyle())
        .help("Toggle terminal — right-click for terminal actions")
        .contextMenu {
            Button("Show Fullscreen Terminal") {
                NotificationCenter.default.post(name: .pigShowTerminal, object: nil)
            }
            Button("Open Vertical Split") {
                NotificationCenter.default.post(name: .pigShowVerticalTerminalSplit, object: nil)
            }
            Button("Open Horizontal Split") {
                NotificationCenter.default.post(name: .pigShowHorizontalTerminalSplit, object: nil)
            }
            Button("New Terminal Tab") {
                NotificationCenter.default.post(name: .pigNewTerminalTab, object: nil)
            }
            Divider()
            Button("Close Split") {
                NotificationCenter.default.post(name: .pigCloseTerminalSplit, object: nil)
            }
            .disabled(!isSplitActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pigTerminalSplitActiveChanged)) { notification in
            isSplitActive = (notification.object as? Bool) ?? false
        }
    }
}

struct TitlebarSessionControls: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel

    private var selectedTitle: String {
        if let project = model.selectedProject { return project.displayName }
        return "Select Project"
    }

    @State private var projectMenuOpen = false
    var body: some View {
        HStack(spacing: 6) {
            Button {
                projectMenuOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text(selectedTitle)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(AppFonts.ui(9, weight: .bold))
                        .foregroundStyle(appTheme.muted)
                }
                .font(AppFonts.ui(12.5, weight: .semibold))
                .foregroundStyle(appTheme.text)
                .frame(maxWidth: 190)
                .frame(height: 18)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Select project")
            .popover(isPresented: $projectMenuOpen, arrowEdge: .bottom) {
                ProjectPickerMenu(
                    width: 250,
                    showsPinButtons: true,
                    isSelected: { model.selectedProjectPath == $0.path },
                    selectProject: { model.selectProject($0) },
                    dismiss: { projectMenuOpen = false }
                )
            }

            Button {
                if let path = model.selectedProject?.path {
                    model.showNewChatHome(projectPath: path)
                }
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .disabled(model.selectedProject == nil)
            .help(model.sessionLaunchExtensions.isEmpty ? "New chat" : "New chat — right-click for session extensions")
            .contextMenu {
                if let path = model.selectedProject?.path {
                    newChatContextMenu(projectPath: path)
                }
            }

            Button {
                model.showNewChatHome(quickChat: true)
            } label: {
                Image(systemName: "bolt.fill")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help(model.sessionLaunchExtensions.isEmpty ? "New quick chat" : "New quick chat — right-click for session extensions")
            .contextMenu {
                Button {
                    model.showNewChatHome(quickChat: true)
                } label: {
                    Label("New Quick Chat", systemImage: "bolt.fill")
                }
                if !model.sessionLaunchExtensions.isEmpty {
                    Divider()
                    ForEach(model.sessionLaunchExtensions) { item in
                        Button {
                            model.newQuickChat(extensionPaths: [item.path])
                        } label: {
                            Label("New Quick Chat with \(item.displayName)", systemImage: "puzzlepiece.extension")
                        }
                    }
                }
            }
        }
        .fixedSize()
    }

    private func startNewChat(projectPath: String, extensionPaths: [String] = []) {
        projectMenuOpen = false
        model.newSession(projectPath: projectPath, extensionPaths: extensionPaths)
    }

    @ViewBuilder
    private func newChatContextMenu(projectPath: String) -> some View {
        Button {
            projectMenuOpen = false
            model.showNewChatHome(projectPath: projectPath)
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
        if !model.sessionLaunchExtensions.isEmpty {
            Divider()
            ForEach(model.sessionLaunchExtensions) { item in
                Button {
                    startNewChat(projectPath: projectPath, extensionPaths: [item.path])
                } label: {
                    Label("New Chat with \(item.displayName)", systemImage: "puzzlepiece.extension")
                }
            }
        }
    }
}

struct CustomActionsToolbarButton: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var editingAction: CustomAction?
    @State private var creating = false
    @State private var menuOpen = false

    private var actions: [CustomAction] { model.selectedCustomActions }

    private var lastAction: CustomAction? {
        if let id = model.selectedLastCustomActionID, let action = actions.first(where: { $0.id == id }) { return action }
        return actions.first
    }

    private var orderedActions: [CustomAction] {
        guard let lastAction else { return actions }
        return [lastAction] + actions.filter { $0.id != lastAction.id }
    }

    var body: some View {
        HStack(spacing: 3) {
            Button(action: primaryAction) {
                HStack(spacing: 5) {
                    if let lastAction {
                        Image(systemName: lastAction.symbolName)
                            .font(AppFonts.ui(12.5, weight: .semibold))
                        Text(lastAction.title)
                            .font(AppFonts.ui(12.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Image(systemName: "plus")
                            .font(AppFonts.ui(11.5, weight: .bold))
                        Text("add")
                            .font(AppFonts.ui(12.5, weight: .semibold))
                    }
                }
                .frame(maxWidth: 136, minHeight: 18, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.selectedController == nil)

            Button { menuOpen.toggle() } label: {
                Image(systemName: "chevron.down")
                    .font(AppFonts.ui(9, weight: .bold))
                    .foregroundStyle(appTheme.muted)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.selectedController == nil)
            .popover(isPresented: $menuOpen, arrowEdge: .bottom) {
                actionsMenu
            }
        }
        .fixedSize()
        .help("Custom actions")
        .sheet(isPresented: $creating) {
            CustomActionEditor(action: nil) { action in
                model.upsertCustomAction(action)
                creating = false
            } onDelete: { _ in } onCancel: {
                creating = false
            }
        }
        .sheet(item: $editingAction) { action in
            CustomActionEditor(action: action) { updated in
                model.upsertCustomAction(updated)
                editingAction = nil
            } onDelete: { deleted in
                model.deleteCustomAction(deleted)
                editingAction = nil
            } onCancel: {
                editingAction = nil
            }
        }
    }

    private var actionsMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(orderedActions) { action in
                CustomActionMenuRow(
                    action: action,
                    run: {
                        menuOpen = false
                        model.runCustomAction(action)
                    },
                    edit: {
                        menuOpen = false
                        editingAction = action
                    }
                )
            }
            if !orderedActions.isEmpty {
                PopoverMenuDivider()
            }
            PopoverPickerRow(title: "Add Custom Action", icon: "plus", checkmarkColumn: false) {
                menuOpen = false
                creating = true
            }
        }
        .padding(.vertical, 5)
        .frame(width: 240)
    }

    private func primaryAction() {
        if let lastAction {
            model.runCustomAction(lastAction)
        } else {
            creating = true
        }
    }
}

private struct CustomActionMenuRow: View {
    @Environment(\.appTheme) private var appTheme
    let action: CustomAction
    let run: () -> Void
    let edit: () -> Void
    @State private var hoveringPencil = false

    var body: some View {
        PopoverPickerRow(title: action.title, icon: action.symbolName, checkmarkColumn: false, action: run) { rowHovering in
            Button(action: edit) {
                Image(systemName: "pencil")
                    .font(AppFonts.ui(11))
                    .foregroundStyle(hoveringPencil ? appTheme.brass : appTheme.muted)
                    .opacity(hoveringPencil ? 1 : (rowHovering ? 0.9 : 0.35))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringPencil = $0 }
            .help("Edit")
        }
    }
}

private struct CustomActionEditor: View {
    @Environment(\.appTheme) private var appTheme
    private static let symbols = [
        "play.fill", "triangle.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "terminal.fill", "gearshape.fill", "bolt.fill", "arrow.clockwise",
        "shippingbox.fill", "testtube.2", "ladybug.fill", "doc.text.fill"
    ]

    @State private var action: CustomAction
    let isNew: Bool
    let onSave: (CustomAction) -> Void
    let onDelete: (CustomAction) -> Void
    let onCancel: () -> Void

    init(action: CustomAction?, onSave: @escaping (CustomAction) -> Void, onDelete: @escaping (CustomAction) -> Void, onCancel: @escaping () -> Void) {
        _action = State(initialValue: action ?? CustomAction(title: "", command: "", symbolName: "play.fill"))
        isNew = action == nil
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add Custom Action" : "Edit Custom Action")
                .font(AppFonts.heading(20, weight: .semibold))
                .foregroundStyle(appTheme.text)

            TextField("Title", text: $action.title)
                .textFieldStyle(.roundedBorder)

            Picker("Icon", selection: $action.symbolName) {
                ForEach(Self.symbols, id: \.self) { symbol in
                    Label(symbol, systemImage: symbol).tag(symbol)
                }
            }
            .pickerStyle(.menu)

            TextEditor(text: $action.command)
                .font(AppFonts.code(12.5))
                .frame(width: 520, height: 150)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(appTheme.codeBackground.opacity(0.24)))

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { onDelete(action) }
                }
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") { onSave(action) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .background(appTheme.panel)
    }
}
