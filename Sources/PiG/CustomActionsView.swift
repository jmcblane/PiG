import SwiftUI
import AppKit

struct TitlebarIconButtonStyle: ButtonStyle {
    @Environment(\.appTheme) private var appTheme
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppFonts.ui(12.5, weight: .semibold))
            .foregroundStyle(configuration.isPressed || active ? appTheme.brass : appTheme.text)
            .frame(width: 24, height: 20)
            .background(configuration.isPressed ? appTheme.panel2.opacity(0.9) : Color.clear)
            .contentShape(Rectangle())
    }
}

struct TitlebarTerminalButton: View {
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
        .glowPresentationBackground()
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
    @FocusState private var commandFocused: Bool
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

            GlowSection {
                GlowRow("Title") {
                    GlowTextField("Title", text: $action.title)
                        .frame(width: 320)
                }
                GlowRow("Icon") {
                    GlowDropdown(selection: $action.symbolName, options: Self.symbols, label: { $0 }, icon: { $0 })
                }
            }

            GlowSection("Command") {
                TextEditor(text: $action.command)
                    .font(AppFonts.code(12.5))
                    .foregroundStyle(appTheme.text)
                    .scrollContentBackground(.hidden)
                    .focused($commandFocused)
                    .padding(6)
                    .frame(height: 150)
                    .glowField(focused: commandFocused)
                    .padding(10)
            }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { onDelete(action) }
                        .buttonStyle(GlowButtonStyle(kind: .destructive))
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(GlowButtonStyle(kind: .secondary))
                Button("Save") { onSave(action) }
                    .buttonStyle(GlowButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(action.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || action.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 520)
        .padding(18)
        .background(GlowPanelFill())
        .glowPresentationBackground()
    }
}
