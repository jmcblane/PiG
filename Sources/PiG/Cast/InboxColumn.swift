import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Open chats as a list on the left: icon, title, place, and status. Swipe or Delete
/// marks a chat done, drag reorders, and sub-chats sit under their parent.
struct InboxColumn: View {
    static let width: CGFloat = 280
    static let visibilityKey = "PiG.inbox.visible"

    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    @State private var draggingItemID: String?
    @State private var dropTargetID: String?
    @State private var dropAfter = false
    @State private var revealedItemID: String?

    /// Slightly darker than the window so the chat column reads as the focus.
    static func background(_ theme: AppTheme) -> Color {
        let c = theme.palette.background, f = theme.choice.isLight ? 0.96 : 0.86
        return Color(red: c.red * f, green: c.green * f, blue: c.blue * f)
    }

    private var resolvedIDs: [String] { model.sessionInboxIDs.filter(model.isInboxItemResolvable) }

    /// Roots in inbox order; a child whose parent is not open is shown as a root.
    private var rootIDs: [String] {
        let open = Set(resolvedIDs)
        return resolvedIDs.filter { id in
            guard let parent = model.inboxParentID(for: id) else { return true }
            return !open.contains(parent)
        }
    }

    private func children(of parentID: String) -> [String] {
        resolvedIDs.filter { model.inboxParentID(for: $0) == parentID }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // The title bar has new-chat buttons; the list offers them only when it's empty.
                    if rootIDs.isEmpty {
                        InboxLaunchRow(kind: .chat)
                        InboxLaunchRow(kind: .quickChat)
                    }
                    ForEach(rootIDs, id: \.self) { itemID in
                        row(itemID, isChild: model.inboxParentID(for: itemID) != nil)
                        ForEach(children(of: itemID), id: \.self) { childID in
                            row(childID, isChild: true)
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: Self.width)
        .background(Self.background(appTheme))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(appTheme.choice.isLight ? 0 : 0.05)).frame(width: 1)
        }
    }

    private func row(_ itemID: String, isChild: Bool) -> some View {
        InboxSessionItemRow(
            itemID: itemID,
            isChild: isChild,
            draggingItemID: $draggingItemID,
            dropTargetID: $dropTargetID,
            dropAfter: $dropAfter,
            revealedItemID: $revealedItemID,
            reorderingEnabled: true
        )
    }

    private var footer: some View {
        HStack(spacing: 2) {
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help("Settings")
            if let title = model.inboxDismissalUndoTitle {
                Text("Done: \(title)")
                    .font(AppFonts.ui(12))
                    .foregroundStyle(appTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)
                Button("Undo") { model.undoLastInboxDismissal() }
                    .buttonStyle(.plain)
                    .font(AppFonts.ui(12, weight: .semibold))
                    .foregroundStyle(appTheme.brass)
                    .help("Reopen (⇧⌘T)")
                    .fixedSize()
            }
            Spacer(minLength: 4)
            Button {
                NotificationCenter.default.post(name: .pigOpenPalette, object: PaletteScope.sessions.rawValue)
            } label: {
                Image(systemName: "archivebox")
            }
            .buttonStyle(TitlebarIconButtonStyle())
            .help("All sessions and archive (⌘F)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(appTheme.choice.isLight ? 0.4 : 0.04)).frame(height: 1)
        }
    }
}

/// New chat or quick chat, shown as list rows when no chats are open.
private struct InboxLaunchRow: View {
    enum Kind { case chat, quickChat }

    @Environment(\.appTheme) private var appTheme
    @EnvironmentObject private var model: AppModel
    let kind: Kind
    @State private var hovering = false

    private var active: Bool {
        guard model.isComposingNewChat else { return false }
        return kind == .quickChat ? model.composingQuickChat : !model.composingQuickChat && model.selectedProjectPath != nil
    }

    var body: some View {
        Button {
            kind == .chat ? model.startNewChat() : model.showNewChatHome(quickChat: true)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if kind == .chat {
                        Image(systemName: "plus")
                            .font(AppFonts.ui(11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(appTheme.muted.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                            )
                    } else {
                        ChatIconView(icon: .quickChat, size: 30)
                    }
                }
                Text(kind == .chat ? "New chat" : "Quick chat")
                    .font(AppFonts.ui(13))
                Spacer(minLength: 0)
                Text(kind == .chat ? "⌘N" : "⇧⌘N")
                    .font(AppFonts.ui(11))
                    .foregroundStyle(appTheme.muted)
            }
            .foregroundStyle(hovering || active ? appTheme.text : appTheme.secondaryText)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? appTheme.panel2 : hovering ? appTheme.panel.opacity(0.7) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .contextMenu {
            if kind == .chat { NewChatMenuItems() } else { NewQuickChatMenuItems() }
        }
    }
}

private struct InboxDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .shadow(color: color.opacity(0.5), radius: 3)
    }
}

/// Three pulsing dots while a chat works.
private struct InboxWorkingDots: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(appTheme.secondaryText)
                        .frame(width: 3, height: 3)
                        .opacity(reduceMotion ? 0.8 : 0.25 + 0.75 * max(0, sin(t * 4 - Double(index) * 0.9)))
                }
            }
        }
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
            if let chat = model.inboxHermesChat(for: itemID) {
                if let controller = model.hermesControllers[chat.id] {
                    LoadedHermesChatRow(chat: chat, controller: controller, revealedItemID: $revealedItemID)
                } else {
                    HermesChatRow(chat: chat, revealedItemID: $revealedItemID)
                }
            } else if let controller = model.inboxController(for: itemID) {
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
                    .padding(.leading, isChild ? 30 : 10)
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
            title: controller.title.isEmpty ? (controller.isQuickChat ? "Quick chat" : "Untitled") : controller.title,
            projectName: model.agent(for: controller)?.name ?? (controller.isQuickChat ? "Quick chat" : controller.projectName),
            icon: model.chatIcon(for: controller),
            selected: model.selectedControllerID == controller.id,
            working: controller.showsActivityIndicator,
            loaded: controller.isProcessActive,
            finishedUnseen: model.finishedUnseen(controller),
            needsInput: controller.extensionUIPrompt != nil,
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
            projectName: model.agent(forSessionPath: summary.filePath)?.name
                ?? (model.isQuickChatInboxItem(itemID) ? "Quick chat" : model.projectDisplayName(for: summary.projectPath)),
            icon: model.chatIcon(for: summary),
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

private struct LoadedHermesChatRow: View {
    let chat: HermesChatRecord
    @ObservedObject var controller: HermesChatController
    @Binding var revealedItemID: String?

    var body: some View {
        HermesChatRow(chat: chat, revealedItemID: $revealedItemID,
                      working: controller.isWorking, loaded: controller.isLoaded,
                      needsInput: controller.approval != nil)
    }
}

private struct HermesChatRow: View {
    @EnvironmentObject private var model: AppModel
    let chat: HermesChatRecord
    @Binding var revealedItemID: String?
    var working = false
    var loaded = false
    var needsInput = false
    @State private var confirmingDeletion = false

    private var itemID: String { "hermes:\(chat.id)" }

    var body: some View {
        InboxSessionListRow(
            title: chat.title,
            projectName: model.hermesAgent(for: chat)?.name ?? "Hermes",
            icon: model.chatIcon(for: chat),
            selected: model.selectedHermesChatID == chat.id,
            working: working,
            loaded: loaded,
            finishedUnseen: model.hermesUnreadChatIDs.contains(chat.id),
            needsInput: needsInput,
            isChild: false,
            itemID: itemID,
            revealedItemID: $revealedItemID,
            done: { model.markInboxItemDone(itemID) },
            action: { model.selectHermesChat(agentID: chat.agentID, chatID: chat.id) }
        )
        .contextMenu {
            Button("Done", systemImage: "checkmark") {
                revealedItemID = nil
                model.markInboxItemDone(itemID)
            }
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

private struct InboxSessionListRow: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var model: AppModel
    let title: String
    let projectName: String
    let icon: ChatIcon
    let selected: Bool
    let working: Bool
    let loaded: Bool
    let finishedUnseen: Bool
    var needsInput: Bool = false
    let isChild: Bool
    let itemID: String
    @Binding var revealedItemID: String?
    let done: () -> Void
    let action: () -> Void
    @State private var revealAmount: CGFloat = 0
    @State private var interactionStartAmount: CGFloat = 0
    @State private var suppressSelection = false
    @FocusState private var doneFocused: Bool
    @State private var hovering = false

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
                            : appTheme.good.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
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
                .accessibilityValue("\(loaded ? "Loaded" : "Unloaded"), \(needsInput ? "needs input" : working ? "working" : finishedUnseen ? "new reply" : "idle")")
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
        .frame(height: AppFonts.scaled(isChild ? 50 : 66))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
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
            ChatIconView(icon: icon, size: isChild ? 22 : 30)
                .opacity(loaded || selected ? 1 : 0.7)
                .saturation(loaded || selected ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(AppFonts.ui(13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected || loaded ? appTheme.text : appTheme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !isChild {
                    Text(projectName)
                        .font(AppFonts.ui(11.5))
                        .foregroundStyle(appTheme.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Group {
                if needsInput {
                    InboxDot(color: appTheme.brass).help("Needs input")
                } else if working && !selected {
                    InboxWorkingDots().help("Working")
                } else if finishedUnseen {
                    InboxDot(color: appTheme.good).help("New reply")
                }
            }
            .frame(width: 22)
        }
        .padding(.leading, isChild ? 30 : 9)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? appTheme.panel2 : hovering ? appTheme.panel.opacity(0.7) : InboxColumn.background(appTheme))
        }
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(appTheme.brass)
                    .frame(width: 2.5)
                    .padding(.vertical, 10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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

