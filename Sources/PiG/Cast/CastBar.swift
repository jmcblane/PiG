import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Window top bar: the current room (project or agent), the cast of open chats, and window controls.
/// Replaces the sidebar inbox: each open chat is a face, ordered like the inbox.
struct CastBar: View {
    static let height: CGFloat = 66
    /// Space kept clear on each side of the cast for the room label and controls.
    private let sideWidth: CGFloat = 230

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                WindowDragArea()
                HStack(spacing: 0) {
                    Color.clear.frame(width: 78)
                    CastRoomButton()
                    Spacer(minLength: 0)
                    CastTrailingControls()
                }
                .frame(height: 28)
                .padding(.trailing, 12)
                CastRow(width: max(120, geometry.size.width - sideWidth * 2))
                    .padding(.top, 7)
            }
        }
        .frame(height: Self.height)
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
                    Image(systemName: "folder")
                    Text(model.selectedProject?.displayName ?? "Choose project")
                }
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
            }
            TitlebarTerminalButton()
            SessionTreeToolbarButton()
            CustomActionsToolbarButton()
        }
        .fixedSize()
    }
}

// MARK: - Cast row

private struct CastEntry: Identifiable, Equatable {
    let id: String
    let isChild: Bool
    var slotWidth: CGFloat { isChild ? 38 : 52 }
}

private struct CastRow: View {
    @EnvironmentObject private var model: AppModel
    let width: CGFloat
    @State private var draggingID: String?
    @State private var dropTargetID: String?
    @State private var dropAfter = false

    private static let buttonSlot: CGFloat = 52

    /// Roots in inbox order, each followed by its children. A child whose parent is
    /// not open is shown as a root.
    private var entries: [CastEntry] {
        let resolved = model.sessionInboxIDs.filter(model.isInboxItemResolvable)
        let open = Set(resolved)
        var result: [CastEntry] = []
        for id in resolved {
            if let parent = model.inboxParentID(for: id), open.contains(parent) { continue }
            result.append(CastEntry(id: id, isChild: false))
            for child in resolved where model.inboxParentID(for: child) == id {
                result.append(CastEntry(id: child, isChild: true))
            }
        }
        return result
    }

    /// Fits entries into the available width, keeping the selected chat visible.
    private func layout(_ entries: [CastEntry]) -> (visible: [CastEntry], overflow: [CastEntry]) {
        let total = entries.reduce(0) { $0 + $1.slotWidth }
        if total + Self.buttonSlot <= width { return (entries, []) }
        var budget = width - Self.buttonSlot * 2
        var visible: [CastEntry] = []
        for entry in entries {
            guard entry.slotWidth <= budget else { break }
            visible.append(entry)
            budget -= entry.slotWidth
        }
        if let selected = entries.first(where: { model.isInboxItemSelected($0.id) }), !visible.contains(selected) {
            while budget < selected.slotWidth, let last = visible.popLast() { budget += last.slotWidth }
            visible.append(selected)
        }
        let shown = Set(visible.map(\.id))
        return (visible, entries.filter { !shown.contains($0.id) })
    }

    var body: some View {
        let (visible, overflow) = layout(entries)
        HStack(alignment: .top, spacing: 0) {
            ForEach(visible) { entry in
                CastMember(itemID: entry.id, isChild: entry.isChild)
                    .frame(width: entry.slotWidth)
                    .opacity(draggingID == entry.id ? 0.4 : 1)
                    .overlay(alignment: dropAfter ? .trailing : .leading) {
                        if dropTargetID == entry.id, draggingID != entry.id {
                            CastDropIndicator()
                        }
                    }
                    .onDrag {
                        draggingID = entry.id
                        dropTargetID = nil
                        return NSItemProvider(object: entry.id as NSString)
                    }
                    .onDrop(of: [UTType.plainText], delegate: CastDropDelegate(
                        targetID: entry.id,
                        slotWidth: entry.slotWidth,
                        draggingID: $draggingID,
                        dropTargetID: $dropTargetID,
                        dropAfter: $dropAfter,
                        model: model
                    ))
            }
            if !overflow.isEmpty {
                CastOverflowButton(entries: overflow)
                    .frame(width: Self.buttonSlot)
            }
            CastNewChatButton()
                .frame(width: Self.buttonSlot)
        }
        .animation(.smooth(duration: 0.22), value: visible.map(\.id))
        .frame(maxWidth: width)
    }
}

private struct CastDropIndicator: View {
    @Environment(\.appTheme) private var appTheme
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(appTheme.brass)
            .frame(width: 2, height: 38)
            .shadow(color: appTheme.brass.opacity(0.4), radius: 3)
    }
}

private struct CastDropDelegate: DropDelegate {
    let targetID: String
    let slotWidth: CGFloat
    @Binding var draggingID: String?
    @Binding var dropTargetID: String?
    @Binding var dropAfter: Bool
    let model: AppModel

    func dropEntered(info: DropInfo) { updateTarget(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateTarget(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if dropTargetID == targetID { dropTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingID = nil; dropTargetID = nil; dropAfter = false }
        guard let draggingID, draggingID != targetID, dropTargetID == targetID else { return false }
        model.moveInboxItem(draggingID, relativeTo: targetID, after: dropAfter)
        return true
    }

    // Roots reorder among roots; children only among their siblings.
    private func updateTarget(_ info: DropInfo) {
        guard let draggingID, draggingID != targetID else { return }
        let draggedParent = model.inboxParentID(for: draggingID)
        let targetParent = model.inboxParentID(for: targetID)
        guard draggedParent == targetParent else {
            if dropTargetID == targetID { dropTargetID = nil }
            return
        }
        dropTargetID = targetID
        dropAfter = info.location.x > slotWidth / 2
    }
}

// MARK: - Members

enum CastStatus {
    case idle, working, needsInput, unread
}

private struct CastMember: View {
    @EnvironmentObject private var model: AppModel
    let itemID: String
    let isChild: Bool

    var body: some View {
        if let chat = model.inboxHermesChat(for: itemID) {
            if let controller = model.hermesControllers[chat.id] {
                CastLoadedHermesMember(itemID: itemID, chat: chat, controller: controller)
            } else {
                CastHermesMember(itemID: itemID, chat: chat)
            }
        } else if let controller = model.inboxController(for: itemID) {
            CastControllerMember(itemID: itemID, controller: controller, isChild: isChild)
        } else if let summary = model.inboxSummary(for: itemID) {
            CastSummaryMember(itemID: itemID, summary: summary, isChild: isChild)
        }
    }
}

private struct CastControllerMember: View {
    @EnvironmentObject private var model: AppModel
    let itemID: String
    @ObservedObject var controller: SessionController
    let isChild: Bool

    var body: some View {
        let agent = model.agent(for: controller)
        let working = controller.showsActivityIndicator
        CastFaceButton(
            title: controller.title.isEmpty ? (controller.isQuickChat ? "Quick chat" : "Untitled") : controller.title,
            subtitle: agent?.name ?? (controller.isQuickChat ? "Quick chat" : controller.projectName),
            look: model.look(for: controller),
            status: controller.extensionUIPrompt != nil ? .needsInput
                : working ? .working
                : model.finishedUnseen(controller) ? .unread : .idle,
            loaded: controller.isProcessActive,
            selected: model.selectedControllerID == controller.id,
            small: isChild,
            action: { model.selectController(controller) }
        )
        .contextMenu {
            Button("Done", systemImage: "checkmark") { model.markInboxItemDone(itemID) }
                .disabled(working)
            Divider()
            if controller.isQuickChat {
                QuickChatContextMenu(controller: controller)
            } else {
                ControllerSessionContextMenu(controller: controller)
            }
        }
    }
}

private struct CastSummaryMember: View {
    @EnvironmentObject private var model: AppModel
    let itemID: String
    let summary: SessionSummary
    let isChild: Bool

    var body: some View {
        let agent = model.agent(forSessionPath: summary.filePath)
        let quick = model.isQuickChatInboxItem(itemID)
        let working = model.activeController(forSessionPath: summary.filePath) != nil
        CastFaceButton(
            title: summary.title,
            subtitle: agent?.name ?? (quick ? "Quick chat" : model.projectDisplayName(for: summary.projectPath)),
            look: agent?.look ?? Look.seeded(key: summary.filePath, projectPath: quick ? nil : summary.projectPath),
            status: working ? .working : model.finishedUnseen(forSessionPath: summary.filePath) ? .unread : .idle,
            loaded: model.loadedController(forSessionPath: summary.filePath) != nil,
            selected: model.selectedController?.sessionPath == summary.filePath,
            small: isChild,
            action: { model.selectSession(summary) }
        )
        .contextMenu {
            Button("Done", systemImage: "checkmark") { model.markInboxItemDone(itemID) }
                .disabled(working)
            Divider()
            SessionSummaryContextMenu(summary: summary)
        }
    }
}

private struct CastLoadedHermesMember: View {
    let itemID: String
    let chat: HermesChatRecord
    @ObservedObject var controller: HermesChatController

    var body: some View {
        CastHermesMember(
            itemID: itemID,
            chat: chat,
            working: controller.isWorking,
            loaded: controller.isLoaded,
            needsInput: controller.approval != nil
        )
    }
}

private struct CastHermesMember: View {
    @EnvironmentObject private var model: AppModel
    let itemID: String
    let chat: HermesChatRecord
    var working = false
    var loaded = false
    var needsInput = false
    @State private var confirmingDeletion = false

    var body: some View {
        let agent = model.hermesAgent(for: chat)
        CastFaceButton(
            title: chat.title,
            subtitle: agent?.name ?? "Hermes",
            look: agent?.look ?? Look.seeded(key: chat.id, projectPath: nil),
            status: needsInput ? .needsInput
                : working ? .working
                : model.hermesUnreadChatIDs.contains(chat.id) ? .unread : .idle,
            loaded: loaded,
            selected: model.selectedHermesChatID == chat.id,
            small: false,
            action: { model.selectHermesChat(agentID: chat.agentID, chatID: chat.id) }
        )
        .contextMenu {
            Button("Done", systemImage: "checkmark") { model.markInboxItemDone(itemID) }
                .disabled(working)
            Divider()
            Button("Move Local Chat to Trash…", systemImage: "trash", role: .destructive) {
                confirmingDeletion = true
            }
            .disabled(working)
        }
        .alert("Move local Hermes chat to Trash?", isPresented: $confirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.deleteHermesChat(chat.id) }
        } message: {
            Text("\"\(chat.title)\" will be removed from PiG and its local journal moved to Trash. Remote server data is unchanged.")
        }
    }
}

/// One face in the cast. The selected face lifts and shows its chat title.
private struct CastFaceButton: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let subtitle: String
    let look: Look
    let status: CastStatus
    let loaded: Bool
    let selected: Bool
    let small: Bool
    let action: () -> Void
    @State private var hovering = false

    private var size: CGFloat { small ? 26 : 36 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                AgentAvatar(look: look, size: size)
                    .opacity(selected ? 1 : hovering ? 1 : loaded ? 0.9 : 0.72)
                    .saturation(loaded || selected || hovering ? 1 : 0.7)
                    .scaleEffect(selected ? 1.12 : 1, anchor: .bottom)
                    .shadow(color: selected ? Color(lookHex: look.shirt).opacity(0.45) : .clear, radius: 8, y: 4)
                    .overlay(alignment: .topTrailing) { statusBadge.offset(x: small ? 5 : 8, y: -5) }
                    .padding(.top, small ? 10 : 0)
                Text(selected ? title : " ")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 150)
                    .fixedSize()
                    .frame(width: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.75), value: selected)
        .onHover { hovering = $0 }
        .help("\(title)\n\(subtitle)")
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityValue(accessibilityStatus)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var statusBadge: some View {
        switch status {
        case .working:
            CastThinkingBubble()
        case .needsInput:
            CastDot(color: appTheme.brass)
        case .unread:
            CastDot(color: appTheme.good)
        case .idle:
            EmptyView()
        }
    }

    private var accessibilityStatus: String {
        let state: String
        switch status {
        case .working: state = "working"
        case .needsInput: state = "needs input"
        case .unread: state = "new reply"
        case .idle: state = "idle"
        }
        return "\(loaded ? "Loaded" : "Unloaded"), \(state)"
    }
}

private struct CastDot: View {
    @Environment(\.appTheme) private var appTheme
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(appTheme.background, lineWidth: 2))
    }
}

/// Speech bubble with three pulsing dots, shown while a chat is working.
private struct CastThinkingBubble: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(appTheme.text)
                        .frame(width: 3, height: 3)
                        .opacity(reduceMotion ? 0.8 : 0.3 + 0.7 * max(0, sin((t * 4) - Double(index) * 0.9)))
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 6, topTrailingRadius: 6)
                    .fill(appTheme.panel2)
            )
            .overlay(
                UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 2, bottomTrailingRadius: 6, topTrailingRadius: 6)
                    .stroke(appTheme.line, lineWidth: 1)
            )
        }
    }
}

// MARK: - Overflow and new chat

private struct CastOverflowButton: View {
    @Environment(\.appTheme) private var appTheme
    let entries: [CastEntry]

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .pigOpenPalette, object: PaletteScope.chats.rawValue)
        } label: {
            Text("+\(entries.count)")
                .font(AppFonts.ui(12, weight: .semibold))
                .foregroundStyle(appTheme.secondaryText)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(appTheme.panel2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("More open chats")
    }
}

private struct CastNewChatButton: View {
    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var hovering = false

    private var composing: Bool { model.isComposingNewChat }

    var body: some View {
        Button(action: newChat) {
            VStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(AppFonts.ui(13, weight: .semibold))
                    .foregroundStyle(composing || hovering ? appTheme.text : appTheme.muted)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(composing ? appTheme.panel2 : .clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(appTheme.muted.opacity(composing ? 0 : 0.6), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    )
                    .scaleEffect(composing ? 1.12 : 1, anchor: .bottom)
                Text(composing ? "New chat" : " ")
                    .font(AppFonts.ui(11, weight: .semibold))
                    .foregroundStyle(appTheme.text)
                    .fixedSize()
                    .frame(width: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("New chat (⌘N)")
        .contextMenu {
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
            Button("New Quick Chat", systemImage: "bolt.fill") { model.showNewChatHome(quickChat: true) }
            ForEach(model.sessionLaunchExtensions) { item in
                Button("New Quick Chat with \(item.displayName)", systemImage: "puzzlepiece.extension") {
                    model.newQuickChat(extensionPaths: [item.path])
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

    private func newChat() {
        if let agent = model.selectedAgent {
            model.selectAgent(agent.id)
        } else if let path = model.selectedProject?.path {
            model.showNewChatHome(projectPath: path)
        } else {
            model.showNewChatHome(quickChat: true)
        }
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

    func inboxItemLook(_ itemID: String) -> Look {
        if let chat = inboxHermesChat(for: itemID) {
            return hermesAgent(for: chat)?.look ?? Look.seeded(key: chat.id, projectPath: nil)
        }
        if let controller = inboxController(for: itemID) { return look(for: controller) }
        guard let summary = inboxSummary(for: itemID) else { return Look.seeded(key: itemID, projectPath: nil) }
        return sessionLook(summary)
    }

    func look(for controller: SessionController) -> Look {
        agent(for: controller)?.look ?? Look.seeded(
            key: controller.sessionPath ?? controller.id,
            projectPath: controller.isQuickChat ? nil : controller.projectPath
        )
    }

    func sessionLook(_ summary: SessionSummary) -> Look {
        agent(forSessionPath: summary.filePath)?.look
            ?? Look.seeded(key: summary.filePath, projectPath: isQuickChatsProject(summary.projectPath) ? nil : summary.projectPath)
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

    /// True on the new-chat landing, when no open chat or agent is selected.
    var isComposingNewChat: Bool {
        selectedControllerID == nil && selectedHermesChatID == nil && selectedAgentID == nil
    }
}

// MARK: - Faces for chats without an agent

extension Look {
    /// A stable face for `key`. Chats in the same project share a shirt color, so the
    /// project reads at a glance; quick chats (no project) get their own color.
    static func seeded(key: String, projectPath: String?) -> Look {
        var rng = SeededGenerator(seed: stableHash(key))
        func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
        let accessories: [Accessory] = [.none, .none, .none, .glasses, .glasses, .beard]
        let tops: [Top] = [.tee, .tee, .collar, .hoodie]
        let shirt = projectPath.map { shirts[Int(stableHash($0) % UInt64(shirts.count))] } ?? "#ffb703"
        return Look(
            skin: pick(skins), hair: pick(hairs), shirt: shirt,
            pants: pick(pantsColors), shoes: pick(shoeColors), hairStyle: pick(Hair.allCases),
            top: pick(tops), accessory: pick(accessories), accentColor: pick(accents),
            tie: nil, happy: rng.next() % 2 == 0
        )
    }

    /// FNV-1a; `hashValue` is randomized per launch.
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}

/// SplitMix64.
private struct SeededGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
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
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }
}
